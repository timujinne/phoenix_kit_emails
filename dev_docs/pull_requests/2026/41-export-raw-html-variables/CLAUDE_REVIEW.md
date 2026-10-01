# Code Review: PR #41 — Write line_items_html as {{{...}}} when exporting templates

**Reviewed:** 2026-10-01
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/41
**Author:** timujinne
**Head SHA:** 10d4294
**Status:** Merged

## Summary

`mix phoenix_kit_emails.templates.export` writes edited system templates out as
`priv/phoenix_kit_templates/<name>/{subject,text,html}[.<locale>].*` override
files. From `phoenix_kit_templates` 0.2.0 the `html` part HTML-escapes
`{{var}}` values, so a variable that already holds rendered HTML (billing's
`line_items_html`) must be spelled `{{{var}}}` in the file or the invoice table
renders as visible markup. The PR:

- adds `Template.raw_html_variables/0` (`["line_items_html"]`);
- makes `TemplateExport.plan/3` rewrite those names in `.html` files when the
  loaded `phoenix_kit_templates` is >= 0.2.0, and leave the file unchanged plus
  warn on older versions (where `{{{x}}}` renders as `{V}`);
- reports per-file notices, and reconciles them against the real file for
  skipped (already existing) files so a re-run does not repeat a stale warning.

## Verification done

- The placeholder regex is a faithful copy of
  `PhoenixKit.Templates.Substitution`'s, and the triple/double disambiguation
  matches its boundary-case table (`{{{{x}}}}`, `{{{x}}`, `{{x}}}`).
- `line_items_html` is the only pre-rendered-HTML variable any sibling module
  emits (`phoenix_kit_billing` receipt + invoice builders; grepped across the
  workspace). Newsletters' `content` is correctly excluded — its own send path
  has no raw form.
- Rewrite is idempotent, leaves `subject`/`text` alone, and the shipped
  defaults this package compares against still use `{{line_items_html}}`, so
  `edited?/2` is not perturbed.
- Test-support helper that patches the VM-global application spec is only used
  from an `async: false` module, and restores via `on_exit`.

## Issues Found

### 1. [BUG - MEDIUM] `core_pin_conformance_test` failed on main — FIXED
**File:** `test/core_pin_conformance_test.exs`
Not introduced by this PR, but it was the only red test in the suite (580
tests, 1 failure). `fb5a999` deliberately raised the core floor to
`>= 2.21.3`, while the guard still required `2.0.0`, `2.0.7` and `2.1.0` to be
admitted. The test now carries the floor explicitly (`@floor`), admits
floor-and-up across minors, and rejects `2.0.0` and `2.21.2`, so it still
catches the failure it exists for (a `~> 2.N.x` re-narrowing) without
contradicting the intended floor.
**Confidence:** 95/100

### 2. [OBSERVATION] A pre-triple-braced file on an unsupported host is not flagged
**File:** `lib/phoenix_kit/modules/emails/template_export.ex` (`reconcile_skipped_notice/2`)
On `phoenix_kit_templates` < 0.2.0, a *skipped* file an operator already edited
to `{{{line_items_html}}}` produces no notice (only double-brace names are
classified), although at that version it renders as `{<tr>…</tr>}`. Not fixed:
the file is the operator's, the scenario needs an operator to have edited ahead
of the upgrade, and the export task's contract is about what *it* writes.
**Confidence:** 60/100

### 3. [NITPICK] `notices ++ file_notices` inside `map_reduce`
**File:** `template_export.ex` (`rewrite_html_file/3`)
Quadratic in file count in principle; the count is tens of files at most. Left.

## What Was Done Well

- Rewrites are decided by an explicit list, not a naming convention; the
  `_html` suffix is used only to *flag* unknown names, never to rewrite them.
- Notice wording is derived from the real write outcome (`written` /
  `would_write` / `skipped`), and the skipped case is reconciled against the
  file on disk rather than the database content.
- The `unknown_placeholder` advice is version-aware ("do NOT change it to
  triple braces yet" on old `phoenix_kit_templates`).
- Thorough tests, including the task itself and the version-detection fallback.

## Verdict

Approved with fixes — the PR is sound; the only defect found was a stale
guard test already failing on main, now fixed. Shipped as 0.5.2.
