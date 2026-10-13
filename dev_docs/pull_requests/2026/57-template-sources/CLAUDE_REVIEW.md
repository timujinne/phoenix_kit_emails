# Code Review: PR #57 — Show when an active template row shadows a file override or a default

**Reviewed:** 2026-10-13
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/57
**Author:** timujinne
**Head SHA:** fa68a28
**Status:** Merged

## Summary
`TemplateSources.load/1` reads which names have a host file override and which
have a default (core or module), once; `SourceBadges` draws a badge (list) or a
notice (editor) on an *active* row that hides either. Each core API it needs is
probed with `Code.ensure_loaded?` + `function_exported?` first, so on an older
core nothing is drawn and the page works as before.

## Issues Found
Verified the premise against core 2.62.2: `Content.resolve_with_sources/5`
asks `Provider.current().get_active_template_by_name/1` first and only reads
files and defaults when that is `nil`, so an active row does shadow both, and a
non-active row (`layers/2` returns `[]`) does not. `Catalog.entries/0` and
`Overrides.list/1` have the shapes the code reads.

### 1. [OBSERVATION] Sources are read twice per visit to the templates list
`handle_params` runs on the disconnected and the connected mount, so the
override directories are walked twice. Gating on `connected?/1` would make the
badges pop in after the static render, which is worse than a second directory
walk, so it is left.

### 2. [OBSERVATION] Seeded system rows will all carry a "Default shadowed" tag
Every active row whose name is also a catalogue default is tagged. That is the
intended information (and the tag is `badge-info`, only a file override is
`badge-warning`), but expect it on every seeded template.

### 3. [NITPICK] `module_name/1` shows only the last alias segment
`PhoenixKit.Modules.Billing` reads as "Billing". Fine for the sentence.

## What Was Done Well
Defensive loading with a logged fallback; the 500-line test file exercises the
roots / modules injection options instead of mocking the filesystem.

## Verdict
Approved.
