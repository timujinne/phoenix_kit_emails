"""A scripted fake mail host for the tests of the SMTP runner.

Listens on 127.0.0.1 on an ephemeral port (never anything else), prints
`PORT <n>` as its first line and serves one script (the `smtp` part of a test
vector) to every connection until it is killed. Every command it receives is
appended to the log file as one JSON line: {"conn": n, "cmd": "..."}.

Script keys:
  listen        false: bind a port, close it and print it (a refused connection)
  banner        lines sent on connect (null: send nothing and wait)
  banner_then   "close": hang up after the banner
  rules         [{"match": regex, "reply": [lines], "then": "close", "hang": true,
                  "delay": seconds}]
                the first rule whose regex matches the command line wins;
                "hang": read on, never answer; "delay": wait before the reply
Unmatched commands get 500; QUIT gets 221 and a close unless a rule says otherwise.
DATA is answered 554 and logged like any command: the tests assert it never comes.
"""
import argparse
import json
import re
import socket
import sys
import threading
import time

lock = threading.Lock()


def log(path, entry):
    with lock:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")


def send(conn, lines):
    conn.sendall("".join(line + "\r\n" for line in lines).encode("utf-8"))


def serve(conn, number, spec, log_path):
    rules = [(re.compile(r["match"], re.I), r) for r in spec.get("rules", [])]
    buffer = b""
    try:
        banner = spec.get("banner")
        if banner is not None:
            send(conn, banner)
            if spec.get("banner_then") == "close":
                return
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                command = raw.decode("utf-8", "replace").rstrip("\r")
                log(log_path, {"conn": number, "cmd": command})
                rule = next((r for pattern, r in rules if pattern.search(command)), None)
                if rule is not None and rule.get("hang"):
                    continue
                if rule is not None:
                    if rule.get("delay"):
                        time.sleep(rule["delay"])
                    send(conn, rule.get("reply", []))
                    if rule.get("then") == "close":
                        return
                elif command.upper().startswith("QUIT"):
                    send(conn, ["221 2.0.0 Bye"])
                    return
                elif command.upper().startswith("DATA"):
                    send(conn, ["554 5.5.1 no DATA here"])
                else:
                    send(conn, ["500 5.5.1 command not recognized"])
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True, help="path of a JSON file with the script")
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]

    if spec.get("listen") is False:
        listener.close()
        print("PORT %d" % port, flush=True)
        threading.Event().wait()
        return

    listener.listen(16)
    print("PORT %d" % port, flush=True)
    number = 0
    while True:
        conn, _addr = listener.accept()
        number += 1
        threading.Thread(target=serve, args=(conn, number, spec, args.log), daemon=True).start()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
