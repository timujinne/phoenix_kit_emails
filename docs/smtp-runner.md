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

**Use the address the settings section shows after `-Server`.** PhoenixKit mounts its API
under the URL prefix of the kit, `https://example.com/phoenix_kit` by default, so that is the
address to give (`https://example.com/phoenix_kit/api/admin/v1/...` is what the runner calls).
A site that mounts the kit at the root needs no path. The path is kept as given, a trailing
slash, query or fragment is dropped.

## Commands

Run it (stays running; Ctrl+C stops it):

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_...
```

A token on the command line is visible to other programs in the process list. Keep it out of
there by putting it in an environment variable of the PowerShell session first (the runner
reads `PK_SMTP_RUNNER_TOKEN` when neither `-Token` nor `-TokenFile` is given):

```powershell
$env:PK_SMTP_RUNNER_TOKEN = 'pk_...'
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com
```

A command typed at the console may be kept in the console history (older PowerShell
versions save every line; current PSReadLine leaves out lines that look like they hold a
token). Where that matters, give no token and use the hidden prompt below, or `-TokenFile`.

With no token at all, an interactive session asks for it (the input is hidden); a session
that cannot ask (`-NonInteractive`, redirected input, a service) stops with exit code 2 and
the "missing token" message. `-Install` takes the token from any of the sources and stores it
encrypted as described below.

Check the setup and exit (code 0 when nothing failed, 1 otherwise):

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_... -SelfTest
```

Start it automatically when you log on (Windows only). `-Install` first asks the site once and
installs nothing if the token is rejected; if the site cannot be reached at that moment it
installs anyway and warns, so run `-SelfTest` too. The token is stored encrypted with
DPAPI (readable only by your Windows user, on this computer) in
`%LOCALAPPDATA%\PhoenixKitSmtpRunner`, together with a copy of the script and a log; a
Task Scheduler task "PhoenixKit SMTP runner" starts it hidden:

```powershell
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_... -Install
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Uninstall
```

| Parameter | Meaning |
|---|---|
| `-Server <url>` | The site with the kit's URL prefix, `https://example.com/phoenix_kit` (plain `http` only for `localhost` / `127.0.0.1`) |
| `-Token <pk_...>` / `-TokenFile <path>` | The token, or a file holding it (plain, or the encrypted file `-Install` writes). Without both: the environment variable `PK_SMTP_RUNNER_TOKEN`, then a hidden prompt in an interactive session |
| `-SelfTest` | Run the four checks and exit |
| `-Install` / `-Uninstall` | Task Scheduler task and stored token (Windows only; a clear message elsewhere) |
| `-Concurrency <1-20>` | Sessions at the same time, default 4 |
| `-LogFile <path>` | Also write the log to a file (kept under 5 MB). Addresses are masked: `in***@example.com` |

On start the runner runs the self-test, then claims jobs in a loop. It tells the site how it is
doing in every call, so the settings page shows "connected", the computer's name and whether
port 25 is open. A site error makes it wait 5 s, doubling up to 60 s; so does an unexpected error inside the loop (it is logged, the runner goes on). While port 25 is closed it looks again every 10 minutes and starts taking jobs by itself once it opens. A revoked token, or a
site that needs a newer script, stops it with a message. When the site pauses it (too many
refusals or a blocked IP) it says so once and keeps checking in until the pause ends.

## When the runner is away

The site does not wait for a runner for ever. A job the runner took and did not report is given
back after its lease ends, and after the allowed number of lost sessions the address gets the
verdict `not_sure` / `smtp_unavailable`. An address no runner has taken within
`email_verify_smtp_queue_max_age_h` hours (default 48) gets the same verdict, and the batches
waiting for it finish. A background job on the site does this, so it works with no runner
connected. When the site's name server is slow or down, a request for jobs spends at most
`email_verify_smtp_claim_dns_budget_ms` (default 10000) milliseconds on lookups and hands out
what it has; the other addresses wait for the next request.

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
| `[FAIL] 1/4 Site answered HTTP 404 ... check the URL prefix` | Most often `-Server` lacks the kit's URL prefix: the line shows the address that was called, `.../api/admin/v1/emails.claim_smtp_jobs`; use `-Server https://host/phoenix_kit` (copy it from the settings section). Otherwise the machine API is off. |
| `[FAIL] 1/4 Site answered HTTP 5xx / other` | The machine API is off, or the runner tools are hidden. The settings section lists the missing switches. |
| `[FAIL] 1/4 Runner is too old` | The site asks for a newer script. Download it again from the settings section. |
| `[WARN] 2/4 ... has no reverse DNS` | Many mail servers refuse connections from an IP without reverse DNS. Set the HELO name in the settings section (a name that resolves to your IP is best). |
| `[WARN] 2/4 The site sees a local address` | The site saw a loopback, private or link-local address (127.x, ::1, 10.x, 172.16-31.x, 192.168.x, fc00::/7, fe80::/10), or the reverse DNS of the IP is `localhost`: the site is on this machine or network, so there is no public IP to name. The runner tells the site no EHLO name (`helo_auto` null) and says EHLO with the computer's own host name. Run the runner on the machine whose public IP should do the check, or set HELO in the settings section. |
| `[FAIL] 3/4 Port 25 closed (ISP/firewall)` | Outbound port 25 does not work from this computer: ask the ISP or open it in the firewall. Until it works the runner only sends heartbeats and takes no jobs. |
| `[WARN] 3/4 Port 25 connects but ... no 220 banner` | The connection is accepted, but the mail server does not greet: the IP may be on a block list, or something in between intercepts port 25. |
| `[WARN] 3/4 ... no mail host to test` | The site could not name a mail server to test against; set the self-test host in the advanced settings. |
| `[FAIL] 4/4 MAIL FROM is not set on the site` | No usable sender address. Set one in the settings section (placeholder addresses such as `noreply@localhost` or `example.com` do not count). No sessions start until then. |

The runner picks the EHLO name in this order: the HELO name set on the site, the reverse DNS
name of its external IP, the computer's own host name if it is fully qualified (it contains a
dot), the literal of a public IP the site saw (`[203.0.113.5]`), a single-label computer name
(for example `WORKSTATION`; it is not an FQDN, so mail servers that insist on one refuse it),
and `localhost` as the last resort. The literal of a loopback or private address is never sent.
Set a HELO name in the settings section if mail servers refuse the name the runner finds.

Hints are printed in English and Russian. The port 25 check connects to the site's own mail
server (the first MX of the sender's domain, or the host set in the advanced settings), reads
the greeting and says `QUIT`.

## Rolling back the SMTP tables

The migration that creates the SMTP storage (V5) is rolled back by `down` only as far as the
version marker: it never drops a table or a column. After a rollback the tables stay in the
database, with their rows:

- `phoenix_kit_email_verify_smtp_queue` - one row per address that waited for an SMTP
  session (e-mail addresses, the lease of the runner that held them);
- `phoenix_kit_email_verify_runners` - one row per runner key (the runner's name, its public
  IP address and host names);
- `phoenix_kit_email_verify_batches.awaiting_smtp` - a counter column on a table of the
  earlier version.

If you also want that data gone, remove it yourself, in this order:

1. Switch the SMTP mode to `off` and wait until no batch is still waiting for SMTP results
   (switching to `off` settles every queued address).
2. Roll back the migration and deploy the older version of the module. Do not run the SQL
   while a version with the SMTP stage is still deployed: it reads and writes these objects.
3. Take a backup, then run the SQL below. None of it can be undone, and running `up` again
   creates the objects empty. Replace `public` with the schema of the install if it uses
   another prefix.

```sql
DROP TABLE IF EXISTS public.phoenix_kit_email_verify_smtp_queue;
DROP TABLE IF EXISTS public.phoenix_kit_email_verify_runners;
ALTER TABLE public.phoenix_kit_email_verify_batches DROP COLUMN IF EXISTS awaiting_smtp;
```

Data retention: the module does not purge the queue. Rows in the `done` and `cancelled` states
are kept for ever, and a runner row stays after its key is revoked. This is a known gap. On a
busy site, clear old rows with a job of your own, for example:

```sql
DELETE FROM public.phoenix_kit_email_verify_smtp_queue
WHERE state IN ('done', 'cancelled') AND updated_at < now() - interval '90 days';
```

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
