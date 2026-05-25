# Changelog

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
