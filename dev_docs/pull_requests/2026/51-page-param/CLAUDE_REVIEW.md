# Code Review: PR #51 — Fix ?page and ?per_page crashing the emails and templates lists

**Reviewed:** 2026-10-10
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/51
**Author:** timujinne
**Head SHA:** 70b96e1
**Status:** Merged

## Summary
Adds `Utils.parse_int/3`, `parse_page/1` and `clamp_page/2`, then replaces every
`String.to_integer/1` / `Integer.parse/1` on a URL or event param (list pages,
`per_page`, settings numbers, column reorder indices) with the no-raise parser.
Lists now clamp a `?page` past the end to the last page.

## Issues Found
None. Checked specifically:

- `Integer.parse(value)` used to accept trailing junk (`"12abc"` → 12); `parse_int`
  requires a whole integer. That is stricter, but every call site range-checks
  anyway, and the failure path is the existing "enter a valid number" flash.
- `load_email_logs` / `load_templates` now count before listing so the page can be
  clamped; `per_page` has `min: 1`, so `ceil(total / per_page)` cannot divide by zero.
- `count_templates` is now called with filters rebuilt from `build_query_filters/3`
  rather than `query_filters` minus limit/offset; the dropped key was only
  `order_by`, which a count ignores.
- `Blocklist.clamp_page/2` became a `defdelegate` to `Utils`; callers unchanged.

## What Was Done Well
Per-handler tests for every edge (range edges, `nil`, integer payloads), plus
doctests on the helpers. The comment on `@max_page` explains why it matches core's
`UrlState` ceiling.

## Verdict
Approved — no changes needed.
