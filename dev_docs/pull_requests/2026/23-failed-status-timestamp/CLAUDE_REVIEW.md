# Code Review: PR #23 — Record failed_at and a failed event when a send fails

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/23
**Author:** timujinne
**Head SHA:** 07bfe2c
**Status:** Merged

## Summary
`Interceptor.update_after_failure/2` now writes `failed_at` and a `failed`
`Event` next to `status: "failed"`, because the admin list builds its badges
from event rows and timestamp columns and never reads `status`.

## Issues Found

### 1. [OBSERVATION] The event insert is fire-and-forget
`Event.create_event/1` is not matched, so a failed insert leaves a log marked
failed with no event and the list renders only the `send` badge again. The
comment says this is deliberate (a missing event must not turn a failed send
into an error), and nothing else in the path can make it likelier. Left as is.

### 2. [OBSERVATION] One event per failing attempt
The function bumps `retry_count` and is called on each failed attempt, so a log
that fails three times gets three `failed` events and `failed_at` is
overwritten each time. That matches "the last failure" for the timestamp and
"every failure" for the history, which is what an event table is for.

## Verdict
Approved.
