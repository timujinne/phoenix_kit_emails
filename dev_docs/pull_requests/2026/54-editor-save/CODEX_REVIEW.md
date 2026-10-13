# Code Review: PR #54 — Fix the template editor storing fallback text per language and overwriting metadata

**Reviewed:** 2026-10-13
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/54
**Author:** Timujeen (timujinne)
**Head SHA:** 53bb042acddbfb4cf278f505c1b9e9aeb8158e33
**Status:** Merged

## Summary

Rechecked translation persistence, metadata merging and trusted audit options.
Claude's translation fix is retained. Three additional defects were reproduced
with failing regression tests and fixed locally for 0.5.5.

## Issues Found

### 1. [BUG - HIGH] Saving erases translations for languages without a tab — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.ex` lines 630–650

The form submits only enabled locales, while Ecto replaces each submitted map.
Opening an English/German template with German disabled and saving English
therefore deleted German. Regional tabs also deleted the original base-language
key. Validation lost the same content before saving.

The editor now merges submitted translations into the stored field before
validation or saving. A submitted empty value still removes that locale through
the changeset. Context callers retain their existing whole-map replacement
semantics. Regression coverage checks all five translated fields, disabled and
regional locales, and explicit clearing of an optional description.

**Confidence:** 100/100

### 2. [BUG - MEDIUM] The form and preview retain stale state after saving — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.ex` lines 455–467

Successful updates replaced `@template` but kept the old changeset, extracted
variables, title and subtitle. A submit without a preceding validate event
could save new content while still displaying the old form and preview. Even
after validation, the changeset's underlying row and version remained stale.

Success now rebuilds the changeset and derived display state from the saved
row. A regression test saves changed content directly and checks the form,
sample preview, variable list, name and version.

**Confidence:** 100/100

### 3. [BUG - MEDIUM] Context callers can persist non-text description translations — FIXED

**File:** `lib/phoenix_kit/modules/emails/template.ex` line 461

`description` was dropped when blank but never validated as a translation map.
The editor's save guard rejected non-text values, while `create_template` and
`update_template` still accepted nested objects, lists, numbers and booleans.

Description values now use the same string validation as the required fields,
with an explicit allowance for an empty optional map. Regression coverage
rejects non-text values and retains the existing empty-description test.

**Confidence:** 100/100

## What Was Done Well

Audit identities come from trusted context options. Metadata merging preserves
clone provenance, and the save guard refuses malformed translations before
sanitization can hide them.

## Verdict

Approved with fixes. All five new regression tests across PRs #54, #55 and #57
failed before their corresponding fixes. Full validation and the release handoff
are recorded in [FOLLOW_UP.md](../57-template-sources/FOLLOW_UP.md).
