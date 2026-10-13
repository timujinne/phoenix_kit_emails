# Code Review: PR #57 — Show when an active template row shadows a file override or a default

**Reviewed:** 2026-10-13
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/57
**Author:** Timujeen (timujinne)
**Head SHA:** fa68a288863b40fed6b33823ad2b87cba4b68a93
**Status:** Merged

## Summary

Rechecked source precedence and the catalog contract against installed core
2.62.2. Active rows do precede file overrides and defaults. Found one defect in
how the new badges infer default availability.

## Issues Found

### 1. [BUG - MEDIUM] File-only catalog entries are reported as shadowed defaults — FIXED

**File:** `lib/phoenix_kit/modules/emails/template_sources.ex` lines 94–121

`Catalog.entry` declares `defaults` as optional, and core uses an empty map
when it is absent. `TemplateSources` treated every catalog name as having a
default, so an active row for a file-only email incorrectly received a
"Default shadowed" badge.

Default loading now includes entries that declare a zero-arity defaults
callback or a map with nonblank subject/text/HTML/Markdown content. Missing,
empty, caption-only and malformed defaults are excluded. Callbacks are not
evaluated while loading badges; their returned content can depend on locale.

The regression test failed before the fix. Existing fake catalog fixtures now
declare actual map/callback defaults rather than relying on the faulty inference.

**Confidence:** 100/100

### 2. [OBSERVATION] Static and connected mounts each load sources

Retained. Both renders need accurate badges; these are separate LiveView
lifecycles. Later list patches reuse their snapshot, and refresh explicitly
reloads it. A shared cache would introduce invalidation requirements without
evidence that this small directory scan needs it.

### 3. [OBSERVATION] Active seeded rows correctly show a default badge

Retained as an informational badge. These rows really do take precedence over
the declared core/module default. Suppressing that badge would conceal useful
information about why file/default changes have no effect.

## What Was Done Well

Optional APIs are checked before use. File overrides get warning styling,
defaults get informational styling, and badges provide accessible descriptions.

## Verdict

Approved with fixes. See [FOLLOW_UP.md](FOLLOW_UP.md) for validation results and
the local release handoff to Claude.
