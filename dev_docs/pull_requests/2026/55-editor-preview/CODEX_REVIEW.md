# Code Review: PR #55 — Fix the editor preview showing raw placeholders and going stale, and translate its labels

**Reviewed:** 2026-10-13
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/55
**Author:** Timujeen (timujinne)
**Head SHA:** 8f66e62cacb199f58ec219ab12cc6c8d768dd74c
**Status:** Merged

## Summary

Checked sample substitution, locale fallback, preview patching and translated
labels. Found and fixed an existing new-template initialization defect in the
same editor path.

## Issues Found

### 1. [BUG - MEDIUM] New templates lose their starter bodies — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.ex` lines 102–129

The creation path supplied strings for `display_name`, `html_body` and
`text_body`, although the schema expects locale maps. Ecto rejected those casts,
so the starter HTML/text disappeared and the preview was empty. The extracted
variable list was also initialized as empty despite the starter placeholders.

Initialization now writes maps under the selected editor locale and extracts
the starter variables. The regression test opens a new template in Estonian
and checks the suggested display name, both bodies and substituted preview.

**Confidence:** 100/100

## What Was Done Well

The preview uses the production substitution function, and the iframe accepts
updated `srcdoc` while retaining its measured height. Variable descriptions
remain author text; translated hints are only placeholders.

## Verdict

Approved with fixes. The regression test failed before the fix and passes in
the final full suite. Save-state synchronization is documented in the
[PR #54 review](../54-editor-save/CODEX_REVIEW.md).
