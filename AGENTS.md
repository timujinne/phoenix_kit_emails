# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Emails — an Elixir module for email tracking, analytics, templates, and AWS SES/SNS/SQS integration, built as a pluggable module for the PhoenixKit framework. Provides admin LiveViews for managing email logs, templates, metrics, queue, and blocklist. Implements the `PhoenixKit.Email.Provider` behaviour (the template callbacks are gone in core 3.0) for unified email provider integration.

## Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix docs                    # Generate documentation
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Architecture

This is a **library** (not a standalone Phoenix app) that provides email tracking as a PhoenixKit plugin module.

### Core Schemas (all use UUIDv7 primary keys)

- **Log** — email log record with status, recipient, subject, body, headers, provider info
- **Event** — delivery/bounce/complaint/open/click events from AWS SES
- **Template** — the retired database template row, read-only (the export task and `TemplateExport.active_template/1`)
- **EmailLogData** — structured email data for log entries

### Provider Integration

`Provider` implements `PhoenixKit.Email.Provider` (the template callbacks are gone in core 3.0) — the unified email provider interface. Delegates to `Interceptor` (before/after send hooks) and `Templates` (template rendering). Registered on startup via `ApplicationIntegration.register()` which sets `:email_provider` in the application env.

### Contexts

- **Emails** (main module) — system config, log CRUD, event management, analytics/metrics, maintenance
- **Templates** — the `send_email/4` facade (billing calls it), plus the legacy shipped defaults and a read-only dump of the legacy table for `mix phoenix_kit_emails.templates.export`
- **Interceptor** — before-send logging, after-send status updates, rate limit checks
- **Metrics** — engagement metrics, campaign stats, provider performance
- **Archiver** — cleanup old logs, compress bodies, S3 archival
- **RateLimiter** — per-recipient and global rate limiting via Hammer

### SQS Pipeline

AWS SES events flow through SQS:

1. **SQSPollingJob** (Oban worker) — the sole SQS poller; long-polls the queue and self-schedules
2. **SQSProcessor** — parses and processes SQS messages into Event records
3. **SQSPollingManager** — manages Oban polling lifecycle (enable/disable/status), wired to the admin UI toggle

The `Supervisor` kicks off Oban polling at boot conditionally based on settings (`email_enabled`, `email_ses_events`, `sqs_polling_enabled`, and queue URL presence); polling can also be toggled at runtime via `SQSPollingManager` without a restart.

### Outgoing Send Queue

Core offers every outgoing message to `Provider.maybe_enqueue/2` (optional `PhoenixKit.Email.Provider` callback, floor `phoenix_kit ~> 1.7.217`) right after interception, on both delivery paths:

1. **Queue** — decides inline-vs-queued and serializes the `Swoosh.Email` into JSON job args. Every decline is `:continue` ("send it now"), never an error. Never queues when the system is off, `email_queue_enabled` is off, the host declared no `:emails` Oban queue (`runnable?/0`), the caller passed `queue: false`, the message has attachments, or it is authentication mail (unless `email_queue_auth_mail`)
2. **SendJob** — Oban worker (`queue: :emails`, `max_attempts: 5`) that rebuilds the email and re-sends it with `skip_queue: true` + `already_intercepted: true`, so tracking is not duplicated and the job is not offered back to its own queue. Delivery is at-least-once
3. **Status** — one snapshot (`summary/0`) of what the module is actually doing, rendered as the system-status card in the Email Tracking settings section

Callers that route through an explicitly chosen integration (`Mailer.deliver_via_integration/3` with a non-default uuid) must pass `queue: false` — the job re-sends through `deliver_email/2`, which resolves the *default* transport.

### Email Verification

Checks whether addresses are deliverable without sending anything. Public API is `PhoenixKit.Modules.Emails.Verification` (callers pass plain lists of addresses; the engine knows nothing about who owns them): `verify/2`, `results_for/1`, `statuses_for/1` (status/reason/level only, no step log — use it to filter large audiences), `summary/1`, and the batch calls `start_batch/4`, `get_batch/1`, `list_batches/2`, `latest_batch/2`, `cancel_batch/1`, `subscribe_batch/1`, `queue_configured?/0`. The SMTP stage adds `smtp_mode/0`, `runner_status/0`, `subscribe_runner/0`, `clear_runner_pause/0`. The runner script and its set-up are described in `docs/smtp-runner.md`.

1. **Pipeline** (`Verification.Pipeline`) — normalise (+`+tag` strip) → syntax → fake/curse/typo flags → TLD list → disposable list → free/role flags → DNS MX → SMTP. The first final outcome stops the run; flags never change a status. The pipeline never opens an SMTP connection: a passing address is `not_sure`/`smtp_disabled` at level `mx`, or `not_sure`/`smtp_pending` when asked to queue it (`smtp: :enqueue`, mode not `off`); `valid` only ever comes from an SMTP result
2. **DNS** (`Resolver` behaviour, `Resolver.Inet` on `:inet_res`) — names are queried absolute (trailing dot), a negative answer is confirmed by a second query (after a short pause, app env `:verification_confirm_pause_ms`, default 300 ms, max 2000, 0 in tests) before it is cached or becomes `invalid`/`no_mx`, MX hosts that are not host names are dropped, and `email_verify_dns_timeout_ms` is the deadline of one query. Transient failures are `temp`/`dns_error` and never cached. `Hijack` probes a nonexistent name to subtract a DNS-hijacking resolver's address from the implicit-MX fallback; an unanswered probe makes that result uncacheable
3. **Batches** — `start_batch/4` stores a `Batch` with its items (one row per address, in one transaction with the job) and enqueues a `BatchStartWorker`, which enqueues one `VerifyEmailWorker` per pending item; the job args carry only the batch uuid and the item uuid, so no address lands in `oban_jobs` (jobs of an earlier version with the addresses in their args are still accepted, `Batches.lay_out/2`); counters move in SQL, progress is broadcast on `batch_topic/1`. `dns_error` verdicts are snoozed (`Retry`); a greylisted address is not retried by the batch, the SMTP queue does that waiting; an address whose job fails for good is counted `temp` and gets a `temp` row (`Batches.give_up/2`). Error logs mask the local part (`j***@domain`)

4. **SMTP through a runner or from the server** (`email_verify_smtp_mode`: `off` default / `runner` / `local`) — the server connects to port 25 itself only in `local` mode (the built-in runner, below), never in `runner` mode. `Verification.SmtpQueue` holds the addresses waiting for a session (`enqueue/1`, deduplicated by a unique partial index; `cancel_for_batch/1`), hands them out (`claim/3`: sessions of one domain, one live lease per domain site-wide, domain interval, domain/runner pause, `not_before`, a server-made catch-all probe address only when the fact is unknown and the domain is neither free nor disposable) and settles reports (`report/4`: foreign or closed leases ignored; a lease that expired is still accepted until the row is leased again - a sweep puts the row back to `queued` but keeps `lease_token`/`leased_by`, a new lease replaces them). Retries have their own counters on the row (`grey_attempts` up to `email_verify_grey_max_attempts`, `transport_attempts` with the 1 min then 5 min backoff, `lease_expiries` up to `email_verify_smtp_max_attempts`); `attempts` is the total. `Verification.QueueSweepWorker` (Oban queue `:email_verification`, self-rescheduling every 10 minutes while rows are queued/leased or batch items await SMTP; started by the first queued address, optionally also listed in the host's crontab) needs no runner: it takes back expired leases (`expire_leases/1`), gives up rows older than `email_verify_smtp_queue_max_age_h` (`expire_stale/1`, `not_sure`/`smtp_unavailable`) and finishes `awaiting_smtp` items of open batches whose address has a final verdict or no live row (`repair_stranded/1`); with the mode `off` it runs `drain_disabled/0`. `Batches.await_smtp/2` reads the verdict after `SmtpQueue.wait_settled/1`, which waits for a report in flight on that address (it holds the queue row locks until it commits) so that a report that missed the freshly parked item cannot strand it. `claim/3` asks DNS only within `email_verify_smtp_claim_dns_budget_ms`; a dead domain is settled a chunk of 200 rows per transaction. `drain_disabled/0` settles every queued/leased row as `not_sure`/`smtp_disabled` (through the normal result path, finishing the `awaiting_smtp` items) and acts only while the effective mode is `off` - `claim/3` and the runner tool call it, and the settings handler must call it after the mode is changed (`local` and `runner` keep their queue, and switching to `local` starts the built-in runner, `LocalRunner.activate/0`; a transaction that settles several addresses first locks their batches in uuid order, `Batches.lock_awaiting/1`). `Verification.Classifier` is the pure table of reply facts to verdicts (phrases from `Dictionaries.phrases/1`, plus the shipped `smtp_user_unknown.txt`: 12 generic phrases, of which only `user unknown`, `5.1.1` and `invalid recipient` come from the original analysis and the rest were chosen here; they are deliberately narrow, a bare "does not exist" would swallow policy texts; a 5xx with an enhanced status 5.7.x and no user-unknown phrase is a block, never `invalid`); `Verification.Runners` keeps one row per API key (heartbeat on every claim, autopause after 5 failed sessions in a row on 3 domains, `status/0` for the UI, PubSub topic `email_verify:runner`); `Verification.DomainCache.record_session/3` writes catch-all, greylist note, last session and the block counter (2 blocks/hour pause a domain for an hour). `Verification.Runners.runner_protocol_version/0` ("1.0.0") is the `min_version` of every claim answer: the version of the protocol with the runner script (`pk-smtp-runner.ps1` carries the same number and a test checks the two are equal), bumped only when the script or the protocol changes, never with the package version. `Verification.RunnerApi` declares the tools `emails.claim_smtp_jobs` and `emails.report_smtp_results` (scope `emails.smtp_runner:run`, permission `emails`) through `Emails.api_tools/0` — only on a core with the machine API (2.63.0+); on an older core `runner` mode reads as `off`
   **Mode `local` (the built-in runner)** — `Verification.LocalRunner` is a runner like any other, only it lives in the site's own VM: it has one row in `phoenix_kit_email_verify_runners` (`Runners.local_key/0`, a fixed nil-like uuid instead of an API key; `name` is the server's host name, `helo_auto` the EHLO name in use; `Runners.heartbeat_local/2`, `Runners.status/0` returns it in the mode `local` and never a keyed runner), takes sessions with `SmtpQueue.claim/3`, runs them with `Verification.Smtp.Direct` and reports through `SmtpQueue.report/4`, so the classifier, retries, domain throttling and both autopauses apply unchanged. `Smtp.Direct.run/3` is the one place that opens a socket (`:gen_tcp`, `active: false`, connect and read timeouts from settings, 240 s per session) and the Elixir twin of the PowerShell dialogue: `priv/smtp_runner/test_vectors.json` is replayed against it in `smtp/direct_test.exs` (report and commands must equal the vector's - that is what keeps the two dialogues agreeing). HELO = `email_verify_smtp_helo` or the server's own name (`LocalRunner.server_name/0`: FQDN if the system knows one); no usable MAIL FROM, no session (`Direct.run/3` answers `{:error, :no_mail_from}`, `claim` hands out nothing). `Verification.LocalRunnerWorker` (Oban, queue `email_verification`, one job waiting at a time - `unique` over `available`/`scheduled`/`retryable`) runs `LocalRunner.cycle/1` and puts its successor on the queue while anything is queued or leased; the chain is started by `LocalRunner.wake/0` when an address is queued in `local` mode (`Verification.verify/2`) and by `LocalRunner.activate/0` on a switch to `local`, and ends by itself when the mode changes or the queue is empty. A cycle: heartbeat, port 25 self-test against `Runners.selftest_host/0` when it has not run for 10 minutes or since the switch (a `blocked` port starts no session; `unknown` does not stop one), `claim` for the free slots (`LocalRunner.sessions_limit/0`, app env `:verification_local_sessions`, default 3; counted from the queue with `SmtpQueue.sessions_held/2` just before the claim, so overlapping cycles may briefly exceed it; an address is never handed out twice), sessions concurrently in tasks, one `report`. The UI card shows host, EHLO name, port 25, queue and pause (the relay and the status reads run in both `runner` and `local`). Safety: `config :phoenix_kit_emails, verification_smtp_loopback_only: true` (set in `config/test.exs`) makes `Direct` raise before connecting to anything but 127.0.0.0/8 and `::1`, and `verification_smtp_port` (tests: 1) replaces port 25; `no_network_test.exs` keeps `smtp/direct.ex` the only file with a socket, `LocalRunner` its only caller, and DATA out of it.
   **Settings section** — `Web.SettingsSections.SmtpVerification` ("Mailbox verification (SMTP)", id `:emails_verification_smtp`, permission `emails`) on core's Email Sending page: the mode (`Verification.SmtpSettings.save_mode/1` - going to `off` runs `SmtpQueue.drain_disabled/0`), the runner's state (live from `Runners.status/0`), whose key it works with, issuing/revoking the token (`Verification.RunnerKeys`: a key whose only scope is `emails.smtp_runner:run`, one live runner key per site - a new one revokes the old ones the admin may manage, the token is shown once in a modal with the start command), the core-side preconditions with their links (`Verification.RunnerSetup.preconditions/0`: machine API off, `emails` in `api_disabled_modules`, tools in `api_disabled_tools`; the "Enable the machine API" button asks first and writes `api_admin_enabled` with the call Settings -> API uses), `MAIL FROM`/`HELO`/numbers (`SmtpSettings.save/1` validates the whole form, writes nothing unless every field is fine; an empty value deletes the override). Core renders a section with nothing but its `id`, so the signed-in admin is not an assign: the section takes `:phoenix_kit_current_scope` if a host passes it, otherwise `SmtpVerification.Relay` (one small process per page, it also turns the `email_verify:runner` PubSub topic and a 5 s tick into `send_update`s) reads it out of the page process with `:sys.get_state/2` (a few tries) - drop that when core passes the scope itself. The relay and the reads about the runner exist only while the mode is `runner`. The form keeps its typed values on the server (`phx-change`) and "Advanced" is an assign, never a `<details>`: the runner status patches the section every few seconds and morphdom resets DOM-only state. Every action that needs rights reads them again with `PhoenixKit.API.Access.fresh_scope/1`. The script is downloaded from `GET <prefix>/admin/emails/verification/pk-smtp-runner.ps1` (`Web.RunnerScriptController`, admin pipeline + `emails` permission, `priv/smtp_runner/pk-smtp-runner.ps1` served as it is: PowerShell 5.1 reads a UTF-8 file without BOM as ANSI, so the script has a BOM)
5. **Batches and SMTP** — an address that passes MX is parked (`awaiting_smtp`, counted in `Batch.awaiting_smtp`, not in `processed`); the queue finishes it when its final verdict lands (`Batches.settle_awaiting/2`) and the batch is `done` only then. A cached `smtp_disabled`/`smtp_pending`/transient SMTP verdict is not final while the mode is not `off`

Tables (migration chain V5, `Emails.Migrations`): `phoenix_kit_email_verifications` (latest verdict per address), `phoenix_kit_email_verify_domains` (per-domain MX/catch-all/greylist/pause cache), `phoenix_kit_email_verify_batches` (+ `awaiting_smtp` from V5), `phoenix_kit_email_verify_batch_items`, `phoenix_kit_email_verify_smtp_queue`, `phoenix_kit_email_verify_runners`.

**Oban queue** — jobs run on `:email_verification` (`Emails.oban_queues/0` declares it, limit 5). A host whose Oban config predates it must add it by hand or the jobs sit in `available` forever:

```elixir
config :my_app, Oban, queues: [email_verification: 5, ...]
```

**Word lists** — shipped in `priv/email_verification/*.txt` (some empty: `typos`, `fake`, `curse`, `smtp_*`; provenance in `SOURCES.md`). A host can merge more on top from an external directory (`email_verify_lists_dir` setting or `config :phoenix_kit_emails, :verification_lists_dir`, the app env wins); the LetsExtract/Kellerman files are accepted under their own names (`DEA_Sorted.txt`, `FakeAddresses_Sorted.txt`, ...). Lists load once per VM — `Dictionaries.reload/0` after a change. Never commit third-party lists

**Tests** — `FakeResolver` (scripted DNS, also the default resolver in `config/test.exs` so no test reaches real DNS), `SmtpHelpers` (queue/report fixtures), `ApiHarness` (core's API processes, real users and keys) and `FakeSmtpServer` (a scripted mail host on 127.0.0.1, the format of the `smtp` part of a test vector; used by the `Smtp.Direct` and `LocalRunner` tests) in `test/support`; nothing in `Verification` may open a socket except `Smtp.Direct` (`no_network_test.exs`) - SMTP answers in the server-side tests are plain data, and the built-in runner talks to the fake only. Live DNS tests are tagged `:external` and excluded by default (`mix test --include external`)

**The runner script** (`priv/smtp_runner/pk-smtp-runner.ps1`, docs in `docs/smtp-runner.md`) — one file for Windows PowerShell 5.1 and PowerShell 7, UTF-8 **with BOM** (5.1 reads a BOM-less file as ANSI and the Russian hints turn to rubbish); keep 5.1-safe syntax (no `??`, `?:`, `&&`, `ForEach-Object -Parallel`, `-AsHashtable`). `$RunnerVersion` equals `Runners.runner_protocol_version/0` (`smtp_runner_script_test.exs` checks it); bump both together, only when the script or the protocol changes. Hidden parameters `-SmtpPort`, `-StopAfterIdle`, `-TimeScale` exist for the tests only. Tests: `test/smtp_runner/PkSmtpRunner.Tests.ps1` (Pester, runs the real script against `test/support/smtp_runner/fake_smtp.py` and `fake_site.py` on 127.0.0.1; also PSScriptAnalyzer with `PSScriptAnalyzerSettings.psd1`: `PSUseCompatibleSyntax` 5.1/7.0 and `PSUseCompatibleCommands`/`Types` with the Windows PowerShell 5.1 profile) wrapped by `smtp_runner_pester_test.exs` (tag `:pwsh`, about two minutes, skipped with a printed reason when `pwsh`/`python3`/Pester/PSScriptAnalyzer are missing, `mix test --exclude pwsh` to skip on purpose); the shared scenarios are `priv/smtp_runner/test_vectors.json`, which `smtp_runner_vectors_test.exs` checks against the report tool's schema and the `Classifier`. No test opens a connection to a real mail server: sessions go to the fake on an ephemeral port. Not covered here: a real Windows PowerShell 5.1 run, `-Install`/`-Uninstall` (Task Scheduler, DPAPI), an HTTPS handshake

**Known gaps (SMTP stage, not built on purpose)**

- The built-in runner connects over IPv4 only (`:gen_tcp` default family), shows the host name and not the server's public IP (behind a proxy or NAT it would be wrong), and holds one slot of the `email_verification` queue (limit 5, shared with the DNS jobs) for the length of a cycle. A node killed in the middle of a cycle leaves the job `executing` until the host's Oban rescues it (Lifeline); the next queued address starts the chain again meanwhile.
- Rollback: the V5 `down` only moves the version marker; `phoenix_kit_email_verify_smtp_queue`, `phoenix_kit_email_verify_runners` (with e-mail addresses and runner IPs) and `batches.awaiting_smtp` stay. The `DROP TABLE IF EXISTS` / `ALTER TABLE ... DROP COLUMN IF EXISTS` an operator runs to remove them is in `docs/smtp-runner.md` ("Rolling back the SMTP tables").
- Switching the mode to `off` settles the whole backlog inside that request (`drain_disabled/0`, in chunks of 200 rows, each chunk committed on its own, so no progress is lost if the request dies, but a large queue makes the request slow).
- The claim DNS budget (`email_verify_smtp_claim_dns_budget_ms`) is checked between domains; a single lookup can still take up to the resolver's worst case.
- The PowerShell runner bounds the connect phase by its connect timeout only, not by the session hard limit (the server side does).
- The runner reports only the last MX attempt of a domain, not every host it tried.
- Issuing a runner key is not atomic: two concurrent issues can leave two live keys until the next issue.
- No retention sweep: `done`/`cancelled` rows of `phoenix_kit_email_verify_smtp_queue` and rows of `phoenix_kit_email_verify_runners` (a revoked key leaves its row) are kept for ever.
- Every `claim` and `report` call writes an `api.request` row into core's activity log (a runner polling every 30 s adds up); the module cannot switch that off.
- The runner must not send an `Idempotency-Key` header: `replay: false` is declared only where core knows the field (`ControlFields.replay_tool?/1`), and core 2.63.0 does not apply it, so with that header core would answer a repeated `claim` from its stored answer instead of running it (a stale or repeated lease list). Report idempotency is the module's own (lease token), not core's.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional public routes (webhook + export) via `Web.Routes`
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Web Layer

- **Admin** (7 LiveViews): Metrics (dashboard), Emails (list), Details (single email), Queue, Blocklist, Settings, EmailTracking
- **Public** (3 Controllers): `WebhookController` (AWS SNS webhook), `ExportController` (CSV/JSON export), `RunnerScriptController` (the SMTP runner script, admin only)
- **Routes**: `route_module/0` provides public routes (webhook + export); admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Settings Keys

All stored via PhoenixKit Settings with module `"email_system"`:

- `email_enabled` — enable/disable the entire system
- `email_save_body` — save full email body vs preview only
- `email_save_headers` — save email headers
- `email_ses_events` — enable AWS SES event processing
- `email_retention_days` — days to keep emails (default: 90)
- `aws_ses_configuration_set` — AWS SES configuration set name
- `email_compress_body` — compress body after N days
- `email_archive_to_s3` — enable S3 archival
- `email_s3_bucket` — S3 bucket archives are written to
- `email_s3_integration` — Integrations connection that signs archive uploads (unset = ExAws env/instance-role chain)
- `email_sampling_rate` — percentage of emails to fully log
- `email_create_placeholder_logs` — create placeholder logs for orphaned events
- `sqs_polling_enabled` — enable SQS polling
- `sqs_polling_interval_ms` — polling interval
- `email_queue_enabled` — hand outgoing mail to the `:emails` Oban queue (default: **true**, but inert unless the host declared the queue)
- `email_queue_auth_mail` — queue authentication mail too (default: false)
- `email_verify_enabled` — email verification feature switch (default: true)
- `email_verify_smtp_mode` — `off` (default) / `runner` / `local`
- `email_verify_smtp_mail_from` — override of the MAIL FROM address (empty by default: the site's sender, `Mailer.get_from_email/0`; placeholder addresses count as not configured and no session starts); `email_verify_smtp_helo` — EHLO name (empty = the runner's reverse DNS; when the IP has none or the site sees a local address, the machine's host name if it is fully qualified, then a literal of a public IP, then a single-label machine name, then `localhost` - never a loopback/private literal; only a plain host name or an `[x.x.x.x]` literal is passed on, anything else reads as empty); the MAIL FROM handed out is normalised (ASCII, domain lowercase and punycode; a non-ASCII local part would need SMTPUTF8 and counts as not configured)
- `email_verify_rcpt_per_session` / `email_verify_domain_interval_s` — addresses per session, seconds between sessions to one domain (default: 10 / 10)
- `email_verify_smtp_lease_s` / `email_verify_smtp_max_attempts` — how long a runner holds a session, lost sessions before `smtp_unavailable` (default: 300 / 5); the lease is never below `Config.smtp_lease_floor_s/0` (the 240 s hard limit of a session plus 60 s) and the form refuses less
- `email_verify_smtp_queue_max_age_h` — hours a row may wait in the SMTP queue before `QueueSweepWorker` settles it as `not_sure`/`smtp_unavailable` (default: 48; settings store only, not in the form)
- `email_verify_smtp_claim_dns_budget_ms` — the time one `claim/3` may spend on DNS for domains whose cached MX has expired; past it the other such domains stay queued for the next claim, cached ones are still handed out (default: 10000; settings store only)
- `email_verify_smtp_connect_timeout_s` / `email_verify_smtp_read_timeout_s` / `email_verify_smtp_idle_poll_s` — handed to the runner (default: 20 / 30 / 30)
- `email_verify_domain_block_threshold` / `email_verify_domain_block_window_min` / `email_verify_domain_pause_min` — blocks that pause a domain, the window, the pause (default: 2 / 60 / 60)
- `email_verify_runner_fail_sessions` / `email_verify_runner_fail_domains` / `email_verify_runner_pause_min` — runner autopause (default: 5 / 3 / 60)
- `email_verify_smtp_selftest_host` — host of the runner's port 25 self-test (empty = first MX of the MAIL FROM domain, else of the site host)
- `email_verify_ttl_mx_hours` / `email_verify_ttl_no_mx_hours` — cached MX / "no MX" answer (default: 24 / 24)
- `email_verify_ttl_catch_all_days` / `email_verify_ttl_grey_hours` — cached catch-all / greylist facts (SMTP stage; default: 7 / 24)
- `email_verify_ttl_result_days` — a stored verdict is reused this long (default: 30)
- `email_verify_dns_timeout_ms` — deadline of one DNS query (default: 3000)
- `email_verify_disposable_status` — status of a disposable-domain address: `temp` (default, as LetsExtract) or `invalid`; the `disposable` flag is set either way; applied on read to stored verdicts too
- `email_verify_dns_max_attempts` — batch attempts on a transient DNS failure (default: 3)
- `email_verify_grey_retry_minutes` / `email_verify_grey_max_attempts` — greylist retry wait and attempts (default: 20 / 3)
- `email_verify_lists_dir` — optional external word-list directory

### File Layout

```
lib/
├── mix/tasks/phoenix_kit_emails.install.ex  # Install mix task
└── phoenix_kit/modules/emails/
    ├── emails.ex                    # Main module (PhoenixKit.Module behaviour)
    ├── application_integration.ex   # Provider registration on startup
    ├── provider.ex                  # PhoenixKit.Email.Provider implementation
    ├── log.ex                       # Log Ecto schema
    ├── event.ex                     # Event Ecto schema
    ├── template.ex                  # Legacy template row (read-only)
    ├── email_log_data.ex            # EmailLogData struct
    ├── templates.ex                 # send_email/4 + legacy defaults/rows for the export
    ├── interceptor.ex               # Before/after send hooks
    ├── queue.ex                     # Send-queue decision (maybe_enqueue/2) + settings
    ├── send_job.ex                  # Oban worker that delivers one queued message
    ├── status.ex                    # Runtime status snapshot for the settings card
    ├── metrics.ex                   # Analytics and engagement metrics
    ├── archiver.ex                  # Cleanup, compression, S3 archival
    ├── archive_worker.ex            # Hourly Oban cron that calls the archiver
    ├── rate_limiter.ex              # Rate limiting via Hammer
    ├── sqs_processor.ex             # SQS message parsing/processing
    ├── sqs_polling_job.ex           # Oban-based SQS polling
    ├── sqs_polling_manager.ex       # Oban polling lifecycle
    ├── supervisor.ex                # OTP Supervisor for SQS pipeline
    ├── verification.ex              # Email verification API; engine in verification/
    ├── table_columns.ex             # Column definitions for admin tables
    ├── paths.ex                     # Centralized URL path helpers
    ├── utils.ex                     # Shared utilities
    └── web/
        ├── routes.ex                # Public route generation
        ├── webhook_controller.ex    # AWS SNS webhook handler
        ├── export_controller.ex     # CSV/JSON export
        ├── metrics.ex               # Dashboard LiveView
        ├── emails.ex                # Emails list LiveView
        ├── details.ex               # Email details LiveView
        ├── queue.ex                 # Queue LiveView
        ├── blocklist.ex             # Blocklist LiveView
        ├── settings.ex              # Settings LiveView
        └── email_tracking.ex        # Email tracking LiveView
```

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"email_system"`
- **UUIDv7 primary keys** — all schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}` and `uuid_generate_v7()` in migrations (never `gen_random_uuid()`)
- **Oban workers** — SQS polling uses Oban workers; never spawn bare Tasks for async event processing
- **Centralized paths via `Paths` module** — never hardcode URLs or route paths in LiveViews or controllers; use `Paths` helpers or `PhoenixKit.Utils.Routes.path/1` for cross-module links
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere. See `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference (including why parent apps must never hand-register plugin LiveView routes)
- **Public routes from `route_module/0`** — the single public entry point is `Web.Routes`; `route_module/0` returns this module so PhoenixKit registers public routes automatically
- **LiveViews use `PhoenixKitWeb` `:live_view`** — this module uses `use PhoenixKitWeb, :live_view` for correct admin layout integration (sidebar/header)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **Provider registration is automatic** — `ApplicationIntegration.register()` is called during `Supervisor.init/1`; the host app does not need to configure the provider manually
- **Settings via PhoenixKit Settings** — all config is stored in the PhoenixKit settings system, not in application env; use `Emails.get_config/0` and related functions
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_emails]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Versioning & Releases

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.1
git push origin 0.1.1
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.1 \
  --title "0.1.1 - 2026-03-28" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Testing

### Structure

```
test/
├── test_helper.exs                          # ExUnit setup
├── phoenix_kit_emails_test.exs              # Unit tests (behaviour compliance)
└── phoenix_kit_emails_integration_test.exs  # Integration tests
```

### Running tests

```bash
mix test                                        # All tests
mix test test/phoenix_kit_emails_test.exs       # Unit tests only
mix test test/phoenix_kit_emails_integration_test.exs  # Integration tests only
```

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

### Review file format

```markdown
# Code Review: PR #<number> — <title>

**Reviewed:** <date>
**Reviewer:** Claude (claude-opus-4-6)
**PR:** <GitHub URL>
**Author:** <name> (<GitHub login>)
**Head SHA:** <commit SHA>
**Status:** <Merged | Open>

## Summary
<What the PR does>

## Issues Found
### 1. [<SEVERITY>] <title> — <FIXED if resolved>
**File:** <path> lines <range>
<Description, code snippet, fix>
**Confidence:** <score>/100

## What Was Done Well
<Positive observations>

## Verdict
<Approved | Approved with fixes | Needs Work> — <reasoning>
```

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `NITPICK`, `OBSERVATION`

When issues are fixed in follow-up commits, append `— FIXED` to the issue title and update the Verdict section.

Additional files per PR directory:
- `README.md` — PR summary (what, why, files changed)
- `FOLLOW_UP.md` — post-merge issues, discovered bugs
- `CONTEXT.md` — alternatives considered, trade-offs

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Utils (Date, UUID, Routes), Users.Auth.User, Users.Roles
- **Phoenix LiveView** (`~> 1.1`) — Admin LiveViews
- **Oban** (`~> 2.20`) — Background job processing (SQS polling)
- **ExAws** (`~> 2.4`) + SQS/SNS/STS/S3 — AWS integration
- **Hammer** (`~> 7.1`) — Rate limiting (uses host app's `RateLimiter.Backend`)
- **NimbleCSV** (`~> 1.2`) — CSV export
- **Jason** (`~> 1.4`) — JSON encoding/decoding
- **Saxy** (`~> 1.5`) + **SweetXml** (`~> 0.7`) — XML parsing for AWS responses
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis
- **dialyxir** (`~> 1.4`, dev/test) — Type checking
