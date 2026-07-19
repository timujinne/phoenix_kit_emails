# PR #16: Phase 1 "Sending Foundation" — AWS SES credentials move into Integrations

**Author**: @timujinne
**Reviewer**: GLM-5.2, 4 rounds × 2 independent agents (reviewer + component-architect)
**Status**: ✅ Reviewed, fixes applied
**Date**: 2026-07-14

## Goal

Core now owns credentials: `PhoenixKit.Integrations` stores connection keys and
nothing else, encrypted. This module stops keeping its own copy of the AWS SES
access key and secret, and reads them from an Integrations connection instead.

- `Emails.aws_ses_credentials/0` resolves the configured connection; the
  `get_aws_*` getters fall back to the legacy settings so an install that has not
  migrated keeps sending (cb2a9f0).
- Settings gains a picker for which `aws_ses` connection to send through (6427df7).
- `migrate_legacy/0` moves an existing key/secret into an encrypted Integrations
  connection, so the move happens once and by itself (a93e07f).
- Floor raised to `phoenix_kit ~> 1.7.190`, the release that carries the `aws_ses`
  provider (5802df6).

## Verified correct (no action needed)

- **Legacy installs keep working.** The getters fall back to the old settings when
  no connection is configured, and `migrate_legacy/0` is idempotent — covered by
  `migrate_legacy_test.exs` and `aws_credentials_test.exs`.
- **Secrets are encrypted at rest.** `access_key`/`secret_key` land in
  Integrations' `@sensitive_fields`, so they are stored `enc:v1:`-prefixed. (This
  is only true because core PR #633 also fixed the installer, which never set
  `:phoenix_kit, secret_key_base` — without that, every integration secret was
  being written in plaintext. Found while live-testing this PR.)

## BUG - HIGH (found and fixed): soft bounces were being recorded as hard ones

`determine_bounce_status/1` matched on `"Temporary"`. SES does not send that word —
its `bounceType` for a soft bounce is **`"Transient"`**. Every soft bounce
therefore fell through to the permanent branch and was recorded as a hard bounce.

Fixed in f1d7a19; `sqs_processor_test.exs` now pins the exact strings SES sends.

## BUG - HIGH (found and fixed): hard bounces did not stop future sends

A hard bounce marked the email, and then nothing. The same address stayed
sendable, so the next campaign bounced it again — which is precisely how a sender
reputation is destroyed. Hard bounces now add the recipient to the blocklist via
`RateLimiter.add_to_blocklist/2` (ed5728b).

## BUG - MEDIUM (found and fixed): `Provider` never declared the behaviour it implements

`PhoenixKit.Modules.Emails.Provider` implements `PhoenixKit.Email.Provider` — but
it never said so. With no `@behaviour` and no `@impl`, the compiler could not check
a single callback: a renamed or dropped callback in core would have compiled
cleanly here and failed at runtime. Declared, with `@impl` on all 13 callbacks
(14ab463).

## Gate

Full suite green. This PR also brings the module its first test infrastructure
(`test/support/data_case.ex`, `test_repo.ex`, a real `test_helper.exs`), since the
credential and SQS paths could not otherwise be tested at all.

Live on the Hydra Force dev app, against a real SES account: credentials resolve
from Integrations, a real send goes out through them, and a legacy install without
a connection still sends from the old settings.

## Post-merge verification pass — 2026-07-19

Independent re-review after merge, ahead of cutting a Hex release. Read
`provider.ex`, `sqs_processor.ex`, `supervisor.ex`, `emails.ex`'s credential
resolution, and both `web/settings_sections/*` LiveComponents against
`elixir:phoenix-thinking`.

- Confirmed all three bugs above are genuinely fixed in the merged code: the
  `"transient"`/`"temporary"` bounce match, `blocklist_bounced_recipients/1`
  wired into the Permanent-bounce branch, and `@behaviour`/`@impl` on all 14
  `Provider` callbacks.
- Confirmed `invalidate_aws_credentials_cache/0` is actually called at both
  places that change the selected connection (`migrate_legacy/0` and the
  Amazon SES & SQS settings section) — not just referenced in a comment.
- The `Phoenix.HTML.raw/1` calls in `amazon_ses_sqs.html.heex` only wrap
  static gettext strings with hardcoded example values (`AKIAIOSFODNN7EXAMPLE`,
  button labels) — no user input reaches them, not an XSS risk.
- Both settings LiveComponents load their data in `update/2` guarded by
  `Map.has_key?/2` (load once, not on every re-render) — consistent with the
  Iron Law's intent for `live_component`, since `update/2` is `mount/3`'s
  duplicate-call equivalent here.
- `mix.exs`'s dependency comment claiming `phoenix_kit ~> 1.7.190` was "not yet
  published to Hex" was stale — 1.7.203 has been on Hex for a while (`mix.lock`
  already resolves it). Cleaned up the comment; no functional change.
- `mix precommit` (compile --warnings-as-errors, deps.unlock --check-unused,
  hex.audit, format, credo --strict, dialyzer) and `mix test` both pass clean.
  22 of 41 tests are excluded in this environment (no local Postgres) — the
  DB-backed suite this PR added was not re-run here; the "Full suite green"
  claim above and the Hydra Force live test are the coverage for that.

No new issues found. Proceeding to bump 0.1.11 → 0.1.12 and publish.
