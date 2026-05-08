# Changelog

## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKit.Modules.Emails.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

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
