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
