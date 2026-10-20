# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Emails — an Elixir module for email tracking, analytics, templates, and AWS SES/SNS/SQS integration, built as a pluggable module for the PhoenixKit framework. Provides admin LiveViews for managing email logs, templates, metrics, queue, and blocklist. Implements the `PhoenixKit.Email.Provider` behaviour (14 callbacks) for unified email provider integration.

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
- **Template** — email templates with name, subject, body, locale support
- **EmailLogData** — structured email data for log entries

### Provider Integration

`Provider` implements `PhoenixKit.Email.Provider` (14 callbacks) — the unified email provider interface. Delegates to `Interceptor` (before/after send hooks) and `Templates` (template rendering). Registered on startup via `ApplicationIntegration.register()` which sets `:email_provider` in the application env.

### Contexts

- **Emails** (main module) — system config, log CRUD, event management, analytics/metrics, maintenance
- **Templates** — template CRUD, rendering with variable substitution, locale support
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

Checks whether addresses are deliverable without sending anything. Public API is `PhoenixKit.Modules.Emails.Verification` (callers pass plain lists of addresses; the engine knows nothing about who owns them): `verify/2`, `results_for/1`, `statuses_for/1` (status/reason/level only, no step log — use it to filter large audiences), `summary/1`, and the batch calls `start_batch/4`, `get_batch/1`, `list_batches/2`, `latest_batch/2`, `cancel_batch/1`, `subscribe_batch/1`, `queue_configured?/0`. The SMTP stage adds `smtp_mode/0`, `runner_status/0`, `subscribe_runner/0`, `clear_runner_pause/0`. Specs: `docs/superpowers/specs/2026-10-19-email-verification.md` (stage 1), `docs/superpowers/specs/2026-10-20-smtp-runner.md` (SMTP through a remote runner).

1. **Pipeline** (`Verification.Pipeline`) — normalise (+`+tag` strip) → syntax → fake/curse/typo flags → TLD list → disposable list → free/role flags → DNS MX → SMTP. The first final outcome stops the run; flags never change a status. The pipeline never opens an SMTP connection: a passing address is `not_sure`/`smtp_disabled` at level `mx`, or `not_sure`/`smtp_pending` when asked to queue it (`smtp: :enqueue`, mode not `off`); `valid` only ever comes from an SMTP result
2. **DNS** (`Resolver` behaviour, `Resolver.Inet` on `:inet_res`) — names are queried absolute (trailing dot), a negative answer is confirmed by a second query (after a short pause, app env `:verification_confirm_pause_ms`, default 300 ms, max 2000, 0 in tests) before it is cached or becomes `invalid`/`no_mx`, MX hosts that are not host names are dropped, and `email_verify_dns_timeout_ms` is the deadline of one query. Transient failures are `temp`/`dns_error` and never cached. `Hijack` probes a nonexistent name to subtract a DNS-hijacking resolver's address from the implicit-MX fallback; an unanswered probe makes that result uncacheable
3. **Batches** — `start_batch/4` stores a `Batch` and enqueues a `BatchStartWorker` (lays out items), which enqueues one `VerifyEmailWorker` per address; counters move in SQL, progress is broadcast on `batch_topic/1`. `dns_error`/`greylist` verdicts are snoozed (`Retry`); an address whose job fails for good is counted `temp` and gets a `temp` row (`Batches.give_up/2`). Error logs mask the local part (`j***@domain`)

4. **SMTP through a runner** (`email_verify_smtp_mode`: `off` default / `runner` / `local`; `local` has no consumer yet) — the server never connects to port 25 itself in `runner` mode. `Verification.SmtpQueue` holds the addresses waiting for a session (`enqueue/1`, deduplicated by a unique partial index; `cancel_for_batch/1`), hands them out (`claim/3`: sessions of one domain, one live lease per domain site-wide, domain interval, domain/runner pause, `not_before`, a server-made catch-all probe address only when the fact is unknown and the domain is neither free nor disposable) and settles reports (`report/4`: foreign or closed leases ignored, an expired lease not yet re-leased accepted). `Verification.Classifier` is the pure table of reply facts to verdicts (phrases from `Dictionaries.phrases/1`, plus the shipped `smtp_user_unknown.txt`); `Verification.Runners` keeps one row per API key (heartbeat on every claim, autopause after 5 failed sessions in a row on 3 domains, `status/0` for the UI, PubSub topic `email_verify:runner`); `Verification.DomainCache.record_session/3` writes catch-all, greylist note, last session and the block counter (2 blocks/hour pause a domain for an hour). `Verification.RunnerApi` declares the tools `emails.claim_smtp_jobs` and `emails.report_smtp_results` (scope `emails.smtp_runner:run`, permission `emails`) through `Emails.api_tools/0` — only on a core with the machine API (2.63.0+); on an older core `runner` mode reads as `off`
5. **Batches and SMTP** — an address that passes MX is parked (`awaiting_smtp`, counted in `Batch.awaiting_smtp`, not in `processed`); the queue finishes it when its final verdict lands (`Batches.settle_awaiting/2`) and the batch is `done` only then. A cached `smtp_disabled`/`smtp_pending`/transient SMTP verdict is not final while the mode is not `off`

Tables (migration chain V5, `Emails.Migrations`): `phoenix_kit_email_verifications` (latest verdict per address), `phoenix_kit_email_verify_domains` (per-domain MX/catch-all/greylist/pause cache), `phoenix_kit_email_verify_batches` (+ `awaiting_smtp` from V5), `phoenix_kit_email_verify_batch_items`, `phoenix_kit_email_verify_smtp_queue`, `phoenix_kit_email_verify_runners`.

**Oban queue** — jobs run on `:email_verification` (`Emails.oban_queues/0` declares it, limit 5). A host whose Oban config predates it must add it by hand or the jobs sit in `available` forever:

```elixir
config :my_app, Oban, queues: [email_verification: 5, ...]
```

**Word lists** — shipped in `priv/email_verification/*.txt` (some empty: `typos`, `fake`, `curse`, `smtp_*`; provenance in `SOURCES.md`). A host can merge more on top from an external directory (`email_verify_lists_dir` setting or `config :phoenix_kit_emails, :verification_lists_dir`, the app env wins); the LetsExtract/Kellerman files are accepted under their own names (`DEA_Sorted.txt`, `FakeAddresses_Sorted.txt`, ...). Lists load once per VM — `Dictionaries.reload/0` after a change. Never commit third-party lists

**Tests** — `FakeResolver` (scripted DNS, also the default resolver in `config/test.exs` so no test reaches real DNS), `SmtpHelpers` (queue/report fixtures) and `ApiHarness` (core's API processes, real users and keys) in `test/support`; nothing in `Verification` may open a socket (`no_network_test.exs`) — SMTP answers in tests are plain data. Live DNS tests are tagged `:external` and excluded by default (`mix test --include external`)

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `route_module/0` provides additional public routes (webhook + export) via `Web.Routes`
5. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
6. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Web Layer

- **Admin** (9 LiveViews): Metrics (dashboard), Emails (list), Details (single email), Templates (list), TemplateEditor (create/edit), Queue, Blocklist, Settings, EmailTracking
- **Public** (2 Controllers): `WebhookController` (AWS SNS webhook), `ExportController` (CSV/JSON export)
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
- `email_verify_smtp_mail_from` — override of the MAIL FROM address (empty by default: the site's sender, `Mailer.get_from_email/0`; placeholder addresses count as not configured and no session starts); `email_verify_smtp_helo` — EHLO name (empty = the runner's reverse DNS)
- `email_verify_rcpt_per_session` / `email_verify_domain_interval_s` — addresses per session, seconds between sessions to one domain (default: 10 / 10)
- `email_verify_smtp_lease_s` / `email_verify_smtp_max_attempts` — how long a runner holds a session, lost sessions before `smtp_unavailable` (default: 300 / 5)
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
    ├── template.ex                  # Template Ecto schema
    ├── email_log_data.ex            # EmailLogData struct
    ├── templates.ex                 # Templates context (CRUD, rendering)
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
        ├── templates.ex             # Templates list LiveView
        ├── template_editor.ex       # Template editor LiveView
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
