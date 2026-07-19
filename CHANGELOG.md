# Changelog

## 0.1.13 - 2026-07-19

### Fixed
- The `/webhooks/ses` route was piped through the host app's `:browser` pipeline, which (per the documented default) includes `protect_from_forgery`. AWS SNS delivers webhook notifications as a cold, session-less POST with no CSRF token, so every notification 403'd with `Plug.CSRFProtection.InvalidCSRFTokenError` before ever reaching `WebhookController`. The route now runs through its own minimal `:phoenix_kit_emails_webhook` pipeline (just `plug :accepts, ["html"]`, no session/CSRF plugs), mirroring the equivalent fix in `phoenix_kit_newsletters`'s one-click-unsubscribe route. (#17)

## 0.1.12 - 2026-07-19

### Changed
- AWS SES credentials now resolve through `PhoenixKit.Integrations` (an encrypted `aws_ses` connection) instead of being stored as plaintext Settings rows. `get_aws_access_key/0`, `get_aws_secret_key/0`, and `get_aws_region/0` prefer the selected Integrations connection and fall back to the legacy Settings/env-var path, so an unmigrated install keeps sending. `migrate_legacy/0` moves an existing key/secret into a new connection once, idempotently, without deleting the legacy Settings rows (an operator confirms the new connection works before blanking them manually).
- The combined credential lookup is cached for 60s (`PhoenixKit.Cache`) so building a send-path AWS config no longer costs 3 Settings reads plus 3 decrypt round-trips per email; `invalidate_aws_credentials_cache/0` is called wherever the selected connection changes.
- Settings moved off this module's own `/admin/settings/emails` tab and now contributes two sections ("Email Tracking", "Amazon SES & SQS") to core's unified `/admin/settings/email-sending` page via `email_settings_sections/0`. `settings.ex`/`settings.html.heex` are gone, replaced by `web/settings_sections/`.
- Requires `phoenix_kit ~> 1.7.190` (the release that carries the `email_settings_sections/0` seam).

### Fixed
- SES bounce classification matched `"Temporary"` for soft bounces, but SES actually sends `"Transient"` — every soft bounce was silently recorded as a hard one. Both strings are now accepted.
- Hard (permanent) bounces are now added to the rate limiter's blocklist, so a bounced address stops receiving future sends instead of bouncing again on the next campaign.
- `PhoenixKit.Modules.Emails.Provider` implements `PhoenixKit.Email.Provider` but never declared `@behaviour`/`@impl` — a renamed or dropped callback in core would have compiled clean here and only failed at runtime. Declared, with `@impl` on all 14 callbacks.
- Boot-time `migrate_legacy/0` no longer makes a live SES API call (`GetSendQuota`, up to 15s) to validate the migrated connection — the credentials were already sending mail before the migration ran, so there was nothing to verify that the first real send wouldn't; this was blocking app startup on network egress.
- `mix hex.publish` refused to build the package with `hackney` declared as `override: true` ("Can't build package with overridden dependency hackney, remove `override: true`"). The override dates back to when `ex_aws_sqs` pinned `hackney ~> 1.9`; since 0.1.11 swapped that for `beamlab_ex_aws_sqs` (which declares no hackney dependency at all), nothing in the tree needs hackney forced above its natural resolution — removed, `mix.lock` unchanged (still resolves 4.6.0).

### Added
- First real test infrastructure for this package (`test/support/data_case.ex`, `test_repo.ex`, `config/test.exs`) — the credential-resolution and SQS bounce/blocklist paths now have DB-backed integration tests instead of being untestable.

## 0.1.11 - 2026-07-12

### Security
- **`ex_aws_sqs` replaced with [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs), matching the switch already made in core (`phoenix_kit` 1.7.188/189).** `ex_aws_sqs` (last released Jan 2023, since archived upstream) pins `hackney ~> 1.9`, which was blocking the `hackney ~> 4.0` upgrade needed to clear a batch of hackney CVEs and made `mix hex.audit` fail on every `precommit`/release. The fork is a maintained drop-in with the same public API (`ExAws.SQS`) and no hackney dependency, but switches SQS from the legacy Query/XML protocol to AWS's JSON protocol, which changes response shapes (`%{"Messages" => [...]}` with string keys like `"ReceiptHandle"`, instead of `%{body: %{messages: [...]}}` with atom keys). `SQSPollingJob` already matched both shapes defensively; `Emails.poll_sqs_for_message/5` and `poll_dlq_for_message/5` (used by the email-details "find delivery events" lookup) only matched the old shape and were updated to match both. `mix hex.audit` now reports zero advisories. Pulls in `phoenix_kit` ~> 1.7.189 and `ex_aws` 2.7.x as part of the same hackney 4.x resolution.

## 0.1.10 - 2026-07-12

### Changed
- Emails admin UI: Settings/Dashboard now share phoenix_kit's core `<.input>`/`<.checkbox>` components instead of hand-rolled markup, section headers sized to match core's other Settings pages, and the breadcrumb reads "Settings / Emails" instead of "Emails Settings".
- AWS Region is now a static searchable dropdown (backed by the `aws_regions` package, now a direct dependency) instead of manual entry plus a "Load regions" AWS API call.

### Fixed
- SES Configuration Set, SNS Topic ARN, and SQS Queue URL/ARN/DLQ settings were only visible in the AWS Configuration card after enabling "AWS SES Events Options", even though "Setup AWS Infrastructure" could already populate them without that toggle — they're now always visible/editable alongside the rest of AWS Configuration.
- The Dashboard's "System Status" card showed a hardcoded "Active" badge regardless of whether email delivery was actually configured.

### Added
- Mailer adapter transparency: `Utils.mailer_adapter_status/0` detects the real Swoosh adapter using the same built-in/delegated-mailer resolution logic as `PhoenixKit.Mailer` itself, and both Settings and the Dashboard now show what's actually configured — plus a copy-pasteable `config.exs` snippet when it's missing or isn't Amazon SES — instead of silently assuming AWS SES everywhere.

## 0.1.9 - 2026-07-08

### Fixed
- `Event.create_event/1` unconditionally inserted with `mode: :savepoint` (added in 0.1.8 to protect `Log.mark_as_opened/2`/`mark_as_clicked/3`'s transactional callers). `:savepoint` mode is not a no-op outside a transaction — it requires one to nest a savepoint in, and raises `DBConnection.TransactionError: transaction is not started` otherwise. Every event created by the SQS processor's non-transactional paths (delivery, bounce, complaint, open, click) was hitting this, so the `phoenix_kit_email_events` audit trail silently stopped populating for messages processed via SQS. Fixed by only requesting `:savepoint` mode when `repo().in_transaction?()` is true.

### Changed
- Dependency bumps (`mix.lock`): `phoenix_kit` 1.7.172 → 1.7.178, plus patch-level updates to `phoenix`, `phoenix_live_view`, `db_connection`, `swoosh`, `mint`, and others.

## 0.1.8 - 2026-06-24

### Added
- Admin UI overhaul for the Emails module: page title/subtitle moved into the admin shell top bar; a daisyUI table toolbar across Emails/Templates/Queue/Blocklist (dropdown filters, a persistent inline search with inline clear, action buttons); clickable column-header sorting (server-side, URL-backed, field-whitelisted) on the contexts that support ordering; body-row click-to-open (Emails/Queue → Details, Templates → edit); a drag-and-drop column customizer on Emails; and a "Get update on this email" per-row status sync. (#13)
- `Send Test` now renders and sends the seeded `test_email` system template (falling back to a built-in body) and records `template_name`, the sending admin's `user_uuid`, and `source_module: "emails"`, so the email Details page shows the template, user, and module. (#13)

### Fixed
- Webhook security (SNS): the signing-certificate URL is locked to `sns.<region>.amazonaws.com` with a `/SimpleNotificationService-*.pem` path before any fetch (blocks forged-cert signature bypass and SSRF); `SignatureVersion` is honored (SHA-1 vs SHA-256); `X-Forwarded-For` is trusted only from configured proxies (new `webhook_trusted_proxies` setting, default empty); and `confirm_subscription/1` actually issues the SubscribeURL GET. (#12)
- Event ingestion: open/click events no longer overwrite terminal statuses (bounced/complaint/rejected/failed); event creation is idempotent via DB unique constraints with graceful `{:ok, :duplicate_event}` mapping; open/click dedup on `occurred_at` preserves multiple distinct engagements while collapsing exact SQS redeliveries; `opened_at`/`clicked_at` are now recorded. (#12)
- SQS pipeline: placeholder logs are inserted directly, bypassing the sampling roll that previously returned `{:ok, :skipped}`, crashed callers, and re-cycled messages forever; the Oban poller is collapsed to exactly one self-healing chain (always self-schedules while enabled, backs off on misconfiguration instead of dying); `Task.yield_many` prevents a slow task from aborting a whole batch; sub-second polling intervals are rejected. (#12)
- The dedup insert in `Event.create_event/1` runs with `mode: :savepoint`, so a unique-constraint violation inside `Log.mark_as_opened/2`/`mark_as_clicked/3`'s transaction no longer aborts the transaction and silently rolls back the status update.
- Analytics: `get_stats_for_period/2` now counts the `complaint` status (it previously matched a `complained` string that is never written, so the metric was always 0) and runs as one grouped query instead of seven aggregate round-trips. (#12)
- The Emails table column customizer validates column ids against the available-column set before persisting, so a crafted client event can no longer store an unknown column. (#13)
- List sorting applies a deterministic UUID (primary-key) tiebreaker, so rows with equal primary-sort values page consistently across the Emails, Templates, and Blocklist lists. (#13)

### Changed
- Archiver body compression truly streams via `Repo.stream` in a transaction (was loading the full result set and only compressing the first batch); CSV exports route every cell through formula-injection + RFC 4180 escaping; `list_logs` no longer preloads `[:user, :events]` on the admin hot path; PubSub status updates refresh a single row instead of reloading the list. (#12)
- Adopt `phoenix_kit` 1.7.165 (provides the core migration backing the email-event dedup unique indexes).

## 0.1.7 - 2026-06-23

### Added
- Live-update the Emails admin list on delivery-status changes via PubSub. `Log.update_log/2` broadcasts a lightweight `{:email_log_updated, …}` event only when a log's status actually changes; the emails LiveView refreshes just the affected on-screen row (no 30-day stats recompute). Best-effort — a PubSub failure can never break the DB write. (#11)

### Fixed
- Consolidate SQS polling onto a single Oban-based poller: remove the legacy 842-line `SQSWorker` GenServer. `SQSPollingJob` + `SQSPollingManager` are now the sole poller and runtime control surface (enable/disable without an app restart). (#11)
- Self-scheduling no longer stalls: the polling job's `unique` constraint excludes running jobs, so an executing job can enqueue its successor and a crash-orphaned job can't permanently block new inserts. (#11)
- SQS messages no longer re-cycle forever: `delete_message/3` returns failures instead of swallowing them as `:ok`, reads both string and atom receipt-handle keys, and won't count an undeleted message as processed. (#11)
- The admin SQS-polling toggle now starts/stops the poller at runtime (routed through `SQSPollingManager`) instead of only persisting the flag and waiting for the next boot. (#11)
- Provider detection classifies a message as `aws_ses` when an SES configuration set is configured, even when the host app sends through its own Swoosh mailer. (#11)
- Post-merge review fixes: compile clean under `--warnings-as-errors` with Oban 2.23 (narrow the polling job's `unique` states to `[:scheduled]`), satisfy `credo --strict` for the new broadcast helper, and drop a stale retired `earmark` entry from the lockfile.

### Changed
- Refresh dependency lockfile (notable bumps: `oban` → 2.23, `phoenix_kit` → 1.7.164, `phoenix_live_view` → 1.2, `swoosh` → 1.26, `tesla` → 1.20, `bandit` → 1.12, `req`).

## 0.1.6 - 2026-05-25

### Added
- Route all 9 Emails admin LiveViews through the per-module `PhoenixKit.Modules.Emails.Gettext` backend, so this package's `ru`/`et` catalogues resolve at render time instead of falling back to English. Extends gettext coverage across the full template surface (IAM/SES setup walkthrough, template editor, blocklist, metrics, queue); `default.pot` grows to 447 msgids. (#9)
- Localise ~100 `put_flash` messages across the Emails LiveViews (settings toggles, errors, confirmations) with `%{var}` interpolation bindings and `en`/`ru`/`et` translations. (#10)

### Fixed
- Correct gettext catalogue mis-fills from the bulk regeneration: 12 `en` entries where `msgstr` ≠ `msgid`, and 7 `ru`/`et` cross-locale mistranslations (e.g. the "Setup AWS Infrastructure" button rendering a stray "3." step prefix; Archive/Clone template tooltips reading "New Template"; `Queued` status showing "Queue").

### Changed
- Require `phoenix_kit ~> 1.7.106` (per-module Gettext backend API).
- Refresh dependency lockfile (notable bumps: `phoenix_kit` 1.7.108→1.7.120, `ecto`/`ecto_sql` 3.13→3.14, `fresco` 0.1→0.6 plus new `etcher`, `tesla` 1.17→1.18, `hammer` 7.3→7.4, `bandit`, `plug`, `req`).

## 0.1.5 - 2026-05-12

### Added
- Wrap Emails settings and email tracking UI strings in `gettext` (47 new msgids in `default.pot`, `en`, `ru`, `et` catalogues). Covers tracking-options toggle labels, data retention block, privacy notice, current configuration table, tracking-benefits headers, IAM/SES setup walkthrough, and remaining placeholders.

### Changed
- Widen Emails settings page to use the full container width on wide screens (drop the `max-w-4xl mx-auto` wrapper). Short numeric inputs keep their `max-w-xs` caps.
- Refresh dependency lockfile to latest compatible versions (notable bumps: `finch` 0.21→0.22, `postgrex` 0.22.1→0.22.2, `swoosh` 1.25.1→1.25.2, `phoenix_kit` 1.7.106→1.7.108, `telemetry` 1.4.1→1.4.2).

## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKit.Modules.Emails.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

### Fixed
- Suppress `EmailInterceptor` Logger warnings when the configured Swoosh adapter is not AWS SES.

### Changed
- Refresh dependency lockfile to latest compatible versions (notable bumps: `bandit`, `db_connection`, `decimal`, `ecto`, `ex_doc`).

## 0.1.3 - 2026-04-12

### Fixed
- Add routing anti-pattern warning to AGENTS.md


All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-04-02

### Fixed

- Changed `css_sources/0` return type from atom to binary to match `PhoenixKit.Module` behaviour callback spec.

### Changed

- Rewrote README to match sibling project structure with full documentation.

## [0.1.1] - 2026-03-27

### Fixed

- Removed `@behaviour` and `@impl` annotations from `Provider` to fix compilation warnings (behaviour defined in host app).
- Suppressed `Hammer` undefined module warning in `WebhookController`.

### Changed

- Rewrote install task to automatically add Tailwind CSS `@source` directive to `app.css` (idempotent).
- Updated `.gitignore` with standard Elixir project entries.

## [0.1.0] - 2026-03-24

### Added

- Initial extraction from PhoenixKit core into a standalone package.
- `PhoenixKit.Email.Provider` behaviour with 14 callbacks.
- AWS SES integration for email sending via SMTP and API.
- AWS SNS webhook processing for bounce, complaint, and delivery notifications.
- AWS SQS polling for asynchronous event ingestion.
- Email tracking and analytics (opens, clicks, deliveries, bounces, complaints).
- 9 admin LiveViews: dashboard, logs, templates, campaigns, recipients, settings, domains, blocklist, tracking.
- Email template management with variable interpolation.
- CSV and JSON export for email logs and analytics.
- Swoosh interceptor for automatic email tracking.
- Rate limiting on webhook endpoints via Hammer.
- SNS signature verification for webhook security.
- CSV formula injection protection in exports.
- Install mix task (`mix phoenix_kit_emails.install`).

[0.1.2]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.2
[0.1.1]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.1
[0.1.0]: https://github.com/BeamLabEU/phoenix_kit_emails/releases/tag/0.1.0
