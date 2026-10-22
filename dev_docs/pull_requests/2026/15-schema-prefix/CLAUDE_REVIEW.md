# Code Review: PR #15 — Add PhoenixKit.SchemaPrefix for runtime named-schema (--prefix) support

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/15
**Author:** mdon
**Head SHA:** 693cdfe
**Status:** Merged

## Summary
`use PhoenixKit.SchemaPrefix` added to the four table-backed schemas (`Log`,
`Event`, `Template`, and `EmailBlocklist`, which lives in `rate_limiter.ex`),
plus `test/schema_prefix_conformance_test.exs`, which fails when a file
declaring `schema "phoenix_kit...` lacks the `use`.

## Issues Found

### 1. [OBSERVATION] The guard matches file contents, not modules
The test greps for the literal `schema "phoenix_kit` and the `use` line per
file. That is why `EmailBlocklist` inside `rate_limiter.ex` is covered, and it
is the reason the test kept protecting the nine schemas PR #58 added later:
all of them carry the `use`. A schema whose table name is built from an
attribute would escape it. None exist.

### 2. [OBSERVATION] `{:hackney, "~> 4.0", override: true}` entered `mix.exs` here
Hex refuses to publish a package that carries an `override: true` dependency,
and neither `mix hex.audit` nor `mix precommit` notices. `mix.exs` today has
`{:hackney, "~> 4.0"}` with no override, so it was cleaned up. Recorded because
it is the kind of thing a release check has to look for.

## Verdict
Approved.
