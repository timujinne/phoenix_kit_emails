"""A minimal stand-in for the PhoenixKit site, for the tests of the SMTP runner.

Serves POST /api/admin/v1/emails.claim_smtp_jobs and /emails.report_smtp_results on
127.0.0.1 (ephemeral port, printed as `PORT <n>` on the first line) and appends every
request to the record file as one JSON line: {"tool", "path", "headers", "body", "status"}.

Config (JSON file):
  token             the bearer token the site accepts (anything else: 401)
  prefix            the kit's URL prefix the API lives under (default ""): a request whose
                    path is not <prefix>/api/admin/v1/<tool> gets 404, as on a real site
  claim             the body of a claim answer; "sessions" is replaced per call
  session_batches   list of lists of sessions: the claims that ask for sessions
                    (max_sessions > 0) get the next list, then empty ones; a claim
                    with max_sessions 0 (heartbeat, self-test) always gets none
  claim_statuses    HTTP status per claim call, in order (default 200), e.g. [200, 503]
  report_statuses   the same for report calls
Answers other than 200 are application/problem+json like core's.
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
state = {"claims": 0, "reports": 0, "batches": 0}


def make_handler(config, record_path):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def log_message(self, *_args):
            pass

        def record(self, tool, body, status):
            headers = {k.lower(): v for k, v in self.headers.items()}
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"tool": tool, "path": self.path, "headers": headers,
                                         "body": body, "status": status}) + "\n")

        def reply(self, status, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            ctype = "application/json" if status == 200 else "application/problem+json"
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(length).decode("utf-8")
            try:
                body = json.loads(raw)
            except ValueError:
                body = {"_raw": raw}
            tool = self.path.rsplit("/", 1)[-1]

            api_base = config.get("prefix", "") + "/api/admin/v1/"

            with lock:
                if not self.path.startswith(api_base):
                    status, payload = 404, {"status": 404, "title": "Not Found", "detail": "No such route."}
                elif self.headers.get("authorization") != "Bearer " + config["token"]:
                    status, payload = 401, {"status": 401, "title": "Unauthorized",
                                            "detail": "Bad or revoked key."}
                elif tool == "emails.claim_smtp_jobs":
                    status, payload = self.claim(body)
                elif tool == "emails.report_smtp_results":
                    status, payload = self.report(body)
                else:
                    status, payload = 404, {"status": 404, "title": "Not Found", "detail": "No such tool."}
                self.record(tool, body, status)
            self.reply(status, payload)

        def scripted(self, key, index):
            statuses = config.get(key, [])
            return statuses[index] if index < len(statuses) else 200

        def claim(self, body):
            index = state["claims"]
            state["claims"] += 1
            status = self.scripted("claim_statuses", index)
            if status != 200:
                return status, {"status": status, "title": "Scripted failure", "detail": "scripted"}
            answer = dict(config["claim"])
            sessions = []
            if body.get("max_sessions", 1) > 0:
                batches = config.get("session_batches", [])
                if state["batches"] < len(batches):
                    sessions = batches[state["batches"]]
                state["batches"] += 1
            answer["sessions"] = sessions
            return 200, answer

        def report(self, body):
            index = state["reports"]
            state["reports"] += 1
            status = self.scripted("report_statuses", index)
            if status != 200:
                return status, {"status": status, "title": "Scripted failure", "detail": "scripted"}
            count = len(body.get("results", []))
            return 200, {"accepted": count, "ignored": 0, "rejected": 0, "settled": count, "paused": None}

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--record", required=True)
    args = parser.parse_args()
    with open(args.config, encoding="utf-8") as handle:
        config = json.load(handle)

    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(config, args.record))
    print("PORT %d" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
