# Code Review: PR #56 — Fix template usage_count losing concurrent updates and counting failed test sends

**Reviewed:** 2026-10-13
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/56
**Author:** timujinne
**Head SHA:** 17dac7c
**Status:** Merged

## Summary
`Templates.track_usage/1` is a single `update_all(inc: [usage_count: 1])` with
`select`, so concurrent sends all count and a stale struct does not matter;
`updated_at` is left alone. The test send counts only when delivery returned
`{:ok, _}` and was not suppressed. `Provider.track_usage/1` now returns `:ok`,
which is what core's `@callback track_usage(map()) :: :ok` declares.

## Issues Found
None. `last_used_at` is `:utc_datetime` and `UtilsDate.utc_now/0` truncates to
seconds, so `update_all` accepts it.

### 1. [OBSERVATION] Core counts before delivery
Core's own sends (`Mailer`, `UserNotifier`, notifications) call
`track_usage` before the transport result is known, so a failed *real* send
still counts. That is core's call order, not this package's, and the callback
cannot see the outcome. Left as is.

## Verdict
Approved.
