# Code Review: PR #54 — Fix the template editor storing fallback text per language and overwriting metadata

**Reviewed:** 2026-10-13
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/54
**Author:** timujinne
**Head SHA:** 53bb042
**Status:** Merged

## Summary
The editor shows what is stored per locale (`Template.stored_translation/3`)
instead of the fallback, empty locales are dropped by the changeset, submitted
`metadata` is merged rather than substituted, and the audit columns are no
longer cast from attrs: the author comes from the session via
`create_template/2` / `update_template/3` / `clone_template/4` options.

## Issues Found

### 1. [BUG - MEDIUM] New editor message shipped without extraction or translation — FIXED
**File:** `priv/gettext/default.pot`, `et` and `ru` `default.po`
`gettext("Every translation must be text. Nothing was saved.")` in
`web/template_editor.ex` was never extracted, so `mix gettext.extract
--check-up-to-date` failed and Estonian/Russian admins got the English text.
Re-extracted the catalogues and added both translations.
**Confidence:** 95/100

### 2. [OBSERVATION] Breaking change for callers that passed the author in attrs
`created_by_user_uuid` / `updated_by_user_uuid` in attrs are now ignored. No
caller in this package or in the sibling modules does that, and the new
options are documented and tested, so no shim was added.

## What Was Done Well
Save refuses a crafted non-string translation instead of silently dropping the
locale; `cloned_from` survives a save; the `down`-compatible metadata merge is
documented ("a key cannot be removed").

## Verdict
Approved with fixes.
