# SMTP runner

`pk-smtp-runner.ps1` checks whether mailboxes exist, from **your own computer**, for a
PhoenixKit site. The site hands it small jobs (a mail domain and a few addresses); the
runner connects to that domain's mail server on port 25, asks `RCPT TO:<address>` and
reports what the server answered. The site decides what the answers mean.

It **never sends a message**: the only SMTP commands are `EHLO`/`HELO`, `MAIL FROM`,
`RCPT TO` and `QUIT`. There is no `DATA` command in the script.

## Requirements

- Windows PowerShell 5.1 (built into Windows 10 and Server 2016+) or PowerShell 7 (`pwsh`).
- Outbound TCP **port 25** from that computer (many ISPs and cloud hosts block it) and HTTPS
  to the site.
- A runner token: *Settings -> Emails -> Mailbox verification (SMTP)*, mode "Runner on your
  computer", button "Issue a new token". The token is shown once. A new token revokes the
  previous one (one runner per site).
- The site must run PhoenixKit core 2.63.0 or later with the machine API (admin audience)
  switched on; the settings section tells you if something is missing.

Download the script from the same settings section (or from
`<site>/<prefix>/admin/emails/verification/pk-smtp-runner.ps1` while signed in as an admin).

## Commands

Run it (stays running; Ctrl+C stops it):

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_...
```

Check the setup and exit (code 0 when nothing failed, 1 otherwise):

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_... -SelfTest
```

Start it automatically when you log on (Windows only; run `-SelfTest` first, `-Install` does not check the token). The token is stored encrypted with
DPAPI (readable only by your Windows user, on this computer) in
`%LOCALAPPDATA%\PhoenixKitSmtpRunner`, together with a copy of the script and a log; a
Task Scheduler task "PhoenixKit SMTP runner" starts it hidden:

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_... -Install
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Uninstall
```

| Parameter | Meaning |
|---|---|
| `-Server <url>` | The site, `https://...` (plain `http` only for `localhost` / `127.0.0.1`) |
| `-Token <pk_...>` / `-TokenFile <path>` | The token, or a file holding it (plain, or the encrypted file `-Install` writes) |
| `-SelfTest` | Run the four checks and exit |
| `-Install` / `-Uninstall` | Task Scheduler task and stored token (Windows only; a clear message elsewhere) |
| `-Concurrency <1-20>` | Sessions at the same time, default 4 |
| `-LogFile <path>` | Also write the log to a file (kept under 5 MB). Addresses are masked: `in***@example.com` |

On start the runner runs the self-test, then claims jobs in a loop. It tells the site how it is
doing in every call, so the settings page shows "connected", the computer's name and whether
port 25 is open. A site error makes it wait 5 s, doubling up to 60 s. A revoked token, or a
site that needs a newer script, stops it with a message. When the site pauses it (too many
refusals or a blocked IP) it says so once and keeps checking in until the pause ends.

## What is sent to the site

- With every call: the script version, the Windows version and PowerShell version, the computer
  name, the result of the port 25 check (`open` / `blocked` / `unknown`) and the reverse DNS
  name of the external IP. The site sees the external IP of the request itself.
- With the results: for every finished session the lease it was given, the mail server used,
  how the connection ended (`answered`, `connect_failed`, `timeout`, `reset`), the code and text
  (up to 512 characters) of each server reply, one reply per address, and the time it took.

Nothing else; the script keeps no data on disk but its own log (and, with `-Install`, the
encrypted token). The site gives the runner the addresses to test and the mail servers to ask.
Every request carries the token as a bearer key; the script never sends an `Idempotency-Key`.

## Troubleshooting by self-test line

```
[OK]   1/4 Site reachable over HTTPS, token accepted
[OK]   2/4 External IP 203.0.113.5, reverse DNS host.example.com
[OK]   3/4 Port 25 open: mx.example.com answered 220 ...
[OK]   4/4 MAIL FROM is set on the site: no***@example.com
```

| Line | Meaning and what to do |
|---|---|
| `[FAIL] 1/4 Token rejected (HTTP 401/403)` | The token was revoked or is wrong. Issue a new one in Settings -> Emails. |
| `[FAIL] 1/4 Site not reachable` | Wrong address, no network, or an HTTPS certificate problem. Open the address in a browser from the same computer. |
| `[FAIL] 1/4 Site answered HTTP 404 / 5xx` | The machine API is off, or the runner tools are hidden. The settings section lists the missing switches. |
| `[FAIL] 1/4 Runner is too old` | The site asks for a newer script. Download it again from the settings section. |
| `[WARN] 2/4 ... has no reverse DNS` | Many mail servers refuse connections from an IP without reverse DNS. Set the HELO name in the settings section (a name that resolves to your IP is best). |
| `[FAIL] 3/4 Port 25 closed (ISP/firewall)` | Outbound port 25 does not work from this computer: ask the ISP or open it in the firewall. Until it works the runner only sends heartbeats and takes no jobs. |
| `[WARN] 3/4 Port 25 connects but ... no 220 banner` | The connection is accepted, but the mail server does not greet: the IP may be on a block list, or something in between intercepts port 25. |
| `[WARN] 3/4 ... no mail host to test` | The site could not name a mail server to test against; set the self-test host in the advanced settings. |
| `[FAIL] 4/4 MAIL FROM is not set on the site` | No usable sender address. Set one in the settings section (placeholder addresses such as `noreply@localhost` or `example.com` do not count). No sessions start until then. |

Hints are printed in English and Russian. The port 25 check connects to the site's own mail
server (the first MX of the sender's domain, or the host set in the advanced settings), reads
the greeting and says `QUIT`.

## Development

The script is `priv/smtp_runner/pk-smtp-runner.ps1`, one file, with a UTF-8 byte order mark
(Windows PowerShell 5.1 reads a file without one as ANSI). `$RunnerVersion` in it equals
`Verification.Runners.runner_protocol_version/0`; bump both only when the script or the
protocol changes.

Tests (`mix test`, tag `:pwsh`, skipped with a printed reason where `pwsh`, `python3`,
Pester 5+ or PSScriptAnalyzer is missing; `mix test --exclude pwsh` skips them on purpose):

- `test/smtp_runner/PkSmtpRunner.Tests.ps1` runs the real script against
  `test/support/smtp_runner/fake_smtp.py` (a scripted mail host) and `fake_site.py` (a stub of
  the claim and report calls), both on `127.0.0.1` with an ephemeral port. The hidden
  parameter `-SmtpPort` points the script at the fake instead of port 25; `-StopAfterIdle`
  and `-TimeScale` only exist to make the loop testable. Nothing here touches a real mail
  server.
- `priv/smtp_runner/test_vectors.json` holds the shared scenarios (normal 250, user unknown,
  catch-all probe, greylist, block with IP, banner 421, connection refused, timeout, multi-line
  EHLO, EHLO 502 -> HELO, MAIL FROM 553, MX fallback): how the fake host behaves, the commands
  the runner must send, the report it must produce, and how the server's `Classifier` must
  read that report. ExUnit checks the report against the report tool's schema and the
  classifier; Pester replays it through the script.
- `test/smtp_runner/PSScriptAnalyzerSettings.psd1` is part of the Pester run:
  `PSUseCompatibleSyntax` (5.1 and 7.0), `PSUseCompatibleCommands` and `PSUseCompatibleTypes`
  with the Windows PowerShell 5.1 profile stand in for a 5.1 machine, which the development
  container does not have. Not covered anywhere here: a real run on Windows PowerShell 5.1,
  `-Install` / `-Uninstall`, and an HTTPS handshake.
