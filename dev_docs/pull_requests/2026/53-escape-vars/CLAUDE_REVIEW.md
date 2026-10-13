# Code Review: PR #53 — Escape template variables in html_body and parse placeholders once

**Reviewed:** 2026-10-13
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/53
**Author:** timujinne
**Head SHA:** ab4eb2e
**Status:** Merged

## Summary
`{{name}}` is HTML-escaped in `html_body`, `{{{name}}}` inserts raw. One
combined, left-to-right regex (`Template.placeholder_regex/0`) now serves
`extract_variables/1`, `substitute_variables/3`, the unbound-placeholder
warning and `TemplateExport`. Migration V3 rewrites the two billing names
(`line_items_html`, `line_items_table_html`) to the raw form in stored rows;
`raw_html_variables/0` stays raw in either spelling so a not-yet-migrated row
still sends a table.

## Issues Found
None blocking. Checked against the producing code:
- Single-pass regex: `{{{x}}}` cannot be half-matched as `{` + `{{x}}` + `}`.
- Core's `Content.resolve_with_sources/5` passes the template to
  `Provider.render_template/3` unchanged, so the escaping applies to every send.
- V3 SQL: lookbehind/lookahead make it idempotent; the names are a frozen
  literal, not `raw_html_variables/0`, as a shipped migration should be; `down/1`
  is the exact inverse for the same two names. Covered by
  `migration_v3_raw_html_test.exs`.

### 1. [OBSERVATION] Hosts must run `mix phoenix_kit.update`
Until V3 runs, the renderer's fallback keeps the two billing names raw, so no
mail breaks. A host template that passes ready-made HTML in any *other* variable
needs `{{{name}}}` by hand; the README upgrade notes say so.

## What Was Done Well
Fallback for un-migrated rows, a frozen name list in the migration, and error
messages that name the variable and the kind of value, never the value.

## Verdict
Approved.
