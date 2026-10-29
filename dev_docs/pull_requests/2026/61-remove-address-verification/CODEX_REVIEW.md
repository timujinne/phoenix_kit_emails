# Code Review: PR #61 — Remove address verification from the module

**Reviewed:** 2026-10-29
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/61
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** c807dc0aab43c2f29971c4b594c72f73fcbb07f3
**Status:** Merged

## Summary

Reviewed the only merge since the previous Codex review, #60. Recent PRs
#53–#60 already have Codex reviews. Checked #61's retained runtime code,
module callbacks, public routes, installer, migration statements, schema
manifest, removed workers' scheduling behavior, and remaining tests against
the installed Hex dependencies, including core 3.0.0 and Oban 2.24.2.

The feature removal is internally consistent. No remaining runtime reference
to the removed verification modules was found. The migrations preserve the
old storage, retain version markers, and omit verification DDL on fresh installs.
Added the missing package upgrade instructions and strengthened preservation
checks; no production Elixir change was necessary.

## Issues Found

### 1. [BUG - MEDIUM] Published documentation omitted required upgrade preparation — FIXED

**File:** `README.md`, upgrade instructions after the feature list

The PR description explains how to retire the verification workers, but that
description is not included in the Hex package or its generated documentation.
The shipped README simply removed the feature. A host following the published
documentation could therefore upgrade with a verification cron entry still
configured. Oban validates that cron workers can be loaded and implement
`perform/1`; a reference to the removed `QueueSweepWorker` prevents startup.
Pending jobs also fail as unknown workers if their queue continues running,
or remain unprocessed after the queue is removed.

Added an ordered procedure to the shipped README: stop new verification work,
disable SMTP while the old implementation still exists, remove cron producers,
settle batch work, pause the verification queue on every node and cancel
remaining jobs, then remove the queue and update. The guide also covers runner
API keys, machine-API configuration, removed public calls, and retained data.
It uses the four exact worker names rather than recommending changes to all
email jobs. No host jobs, settings, or credentials were changed by this review.

**Confidence:** 100/100

### 2. [OBSERVATION] Row-count assertions did not cover retained data values — FIXED

**File:** `test/phoenix_kit/modules/emails/migration_removed_tables_test.exs`,
`legacy_rows/0` and the upgrade/downgrade preservation cases

The existing cases verified each legacy table still contained one row, plus
one batch counter. They would still pass if another column were rewritten
without changing the row count. Replaced those assertions with complete,
ordered row snapshots for all six legacy tables, compared after every upgrade
version and downgrade target. Existing index/constraint definition checks and
the explicit batch-counter assertion remain in place.

This strengthens the preservation guarantee; it does not imply that the
reviewed migration actually changed any retained value.

**Confidence:** 100/100

## What Was Done Well

- V4/V5 remain valid marker versions while adding no verification objects.
- Existing verification data and schemas remain under the host's control.
- The manifest removes retired objects without changing the remaining schema;
  the real-database manifest and repair tests pass.
- Removal covers the settings section, machine-API callbacks, installer queue,
  public runner route, assets, and test-only dependencies together.
- Integration tests exercise fresh and upgraded storage in sandboxed scratch
  schemas, independent of leftover tables in the shared database.

## Validation

- Initial `mix test` against the existing default database stopped before test
  execution: its core V224 marker is below core 3.0's V225 migration floor.
  That database was not reset or manually modified. Created an independent
  scratch test database for this review.
- Full suite on the fresh scratch database: **12 doctests, 860 tests,
  0 failures**. Database integration and manifest/repair cases ran.
- After strengthening the preservation assertions, reran
  `migration_removed_tables_test.exs`: **3 tests, 0 failures**. The scratch
  database was removed after validation.
- Compared pre-merge and current manifest objects for `public` and `tenant_a`:
  **133 retained objects are identical; all 111 removed objects belong to
  verification**.
- `mix format`, final `mix format --check-formatted`, final
  `mix credo --strict`, and `git diff --check`: passed.
- `mix precommit`: passed, including compilation with warnings as errors,
  unused-dependency check, Hex audit, formatting, strict Credo and Dialyzer.
  Dialyzer reports **Total errors: 2, Skipped: 2, Unnecessary Skips: 0**,
  matching the existing filters. No suppressions were added.

## Verdict

Approved with fixes. The runtime removal is sound; the published upgrade
procedure now explains the host preparation required before deploying it,
and preservation checks cover complete row values. Versioning and release
notes remain release work and were not changed in this review.
