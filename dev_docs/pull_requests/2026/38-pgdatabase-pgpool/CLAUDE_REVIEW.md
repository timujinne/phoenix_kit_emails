# Code Review: PR #38 — test: make the test database name overridable via PGDATABASE (+ PGPOOL)

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/38
**Author:** timujinne
**Head SHA:** 6f489d7
**Status:** Merged

## Summary
`config/test.exs` reads `PGDATABASE` and `PGPOOL`, shared by the sandbox repo
and the migration repo, mirroring core's config. Unset, the old names apply.

## Issues Found

### 1. [NITPICK] `MIX_TEST_PARTITION` is ignored once `PGDATABASE` is set
Every partition then shares one database. Same behaviour as core and only
relevant to someone who sets both, so left as is.

### 2. [OBSERVATION] `PGPOOL` bounds the sandbox repo only
`MigrationRepo` keeps `pool_size: 2`. With the workspace rule (pool >= cases +
2) a suite needs `PGPOOL` of at least `--max-cases + 2` plus those two, which
is what I used (`PGPOOL=8 ... --max-cases 6`).

## Verdict
Approved.
