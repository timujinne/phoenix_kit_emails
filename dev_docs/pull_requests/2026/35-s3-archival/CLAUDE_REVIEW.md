# Code Review: PR #35 — emails: S3 archival, from placeholder to a feature that runs

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/35
**Author:** timujinne
**Head SHA:** 5a2b42c
**Status:** Merged (a Grok review already exists beside this one)

## Summary
Archival gets a trigger and bookkeeping: `ArchiveWorker` (hourly cron, own
queue), `archived_at`/`s3_key` columns (migration V2), a batch loop that
uploads, stamps, then optionally deletes, and a retention cleanup that refuses
to delete a row archival still owes an upload. Credentials come from an
Integrations connection (`aws_ses` or `object_storage`). The old code's bugs
are fixed on the way: events written under a key the JSON encoder skips,
`application/gzip` headers on a plain body, colons in object keys.

## Issues Found
None blocking. I traced the failure paths because the loop re-selects "rows
with `archived_at IS NULL`" and would spin if the stamp ever silently
updated nothing:

- Upload fails -> batch returns 0 -> `{:error, :upload_failed}`, run stops.
- Upload succeeds, `mark_archived` raises -> rescued at `process_s3_archival`,
  returned as an error, the Oban job retries. No spin.
- `mark_archived` is `update_all ... WHERE archived_at IS NULL`, so a retry
  cannot overwrite the key of an object already written.

### 1. [OBSERVATION] At-least-once upload
A crash between the upload and the stamp leaves a duplicate object under a new
batch id on the retry. Bucket-side that is harmless (keys are unique per
batch) and it is the safe direction; recorded so nobody tries to make it
exactly-once with more machinery.

### 2. [OBSERVATION] Compression runs before archival
`compress_old_bodies` nulls `body_full` after `email_compress_body` days
(default 30, against 90 days of retention), so an archive written at the retention cutoff
holds `body_preview` only for those rows. If the bucket is meant to be the
full record, the compress age has to be at least the retention age.

### 3. [OBSERVATION] Rows with `sent_at IS NULL`
Neither archival, compression nor cleanup selects them (all compare
`sent_at < cutoff`). That was already true of cleanup, so this is not new,
and it is consistent.

## Verdict
Approved.
