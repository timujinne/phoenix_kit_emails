# Code Review: PR #60 — Record which template layer built each email in the log

**Reviewed:** 2026-10-24
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/60
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 4c479cb7757f58ee2d55624a09f93da046c32ba9
**Status:** Merged; Claude's follow-up `39d819b` rechecked

## Summary

Reviewed #60's first-parent diff and Claude's subsequent fixes against installed
core 2.64.0, including content resolution, auth builders, delivery options,
interception, migration V6, test sends and the details badge. Recent PRs
#53–#59 already have Codex reviews; this pass focuses on the new #60 changes
and runs the full regression suite across the repository.

Claude's private-map fix is correct. Found one additional incorrect attribution
in the editor's test-send path and fixed it.

## Issues Found

### 1. [BUG - MEDIUM] Unsaved editor content was attributed to the saved database row — FIXED

**File:** `lib/phoenix_kit/modules/emails/web/template_editor.ex`
(`saved_template_uuid/2`, test-send handler)

The handler renders a temporary template from the form, but #60 unconditionally
stamped the saved row's UUID and `"db"` source whenever the editor was opened on
an existing template. Changing its subject or either body without saving
therefore produced an email labelled "built from a template stored in the
database", with a link to a row that did not contain the sent content. Claude's
follow-up retained this behavior.

The saved UUID is now used only when the form's name, subject and both body maps
match the saved template snapshot. A new or modified form explicitly sends
`template_source: nil` and no UUID, preventing the interceptor's by-name fallback
from attributing it to the unchanged row. This is conservative: an edit in
another locale also leaves the source unknown. Unchanged saved forms retain
their database badge and link.

Three regression tests, for subject, HTML and text edits, failed before the fix
and pass afterward. They also verify the saved row remains unchanged.

**Confidence:** 100/100

### 2. [OBSERVATION] Claude's auth-mail fix survives the actual core delivery path

`UserNotifier.build_templated/5` stores `content.db_template` under
`email.private[:phoenix_kit_db_template]`; `deliver_built/1` logs the generic
name `"user_notification"` and passes the email through unchanged. Reading this
private value is therefore direct evidence of the database row used. A present
nil value must suppress the lookup of that generic name.

Added tests using core's real `build_welcome/1` and `deliver_built/1`, with the
Swoosh test adapter. They verify both database attribution and the no-database
case even when an unrelated active `user_notification` row exists. These go
beyond constructing the private map manually.

Claude's explicit-source handling also correctly drops UUIDs for file/module
sources. The template cleanup in test setup runs inside `DataCase`'s sandbox
transaction and rolls back; no committed seed rows were manually deleted.

### 3. [OBSERVATION] A reconstructed source is still limited by core's metadata

Retained. Auth messages with a nil private template still cannot distinguish
file overrides from defaults because core does not forward their real template
name. Claude correctly leaves both source and UUID nil for these messages.

The general by-name fallback reconstructs resolution after the content was
built; it is not a record produced by that resolution. Core also strips
per-send `:paths` and `:defaults` before interception, so this fallback cannot
reconstruct those custom choices reliably. Callers that know their source can
already pass `:template_source` explicitly. Fully authoritative attribution
requires core to forward resolved source metadata, including locale and file
choices. No dependency source was patched in this review.

## What Was Done Well

V6 is additive, nullable, replayable and prefix-aware, with no foreign key that
would remove historical logs when a template is deleted. The details view hides
the edit link after row deletion. Explicit unknown sources suppress inference,
and optional source APIs are checked before use.

## Validation

- Reproduced the editor defect with three failing regression tests before the
  production fix; the focused source/migration tests then passed.
- `PGPOOL=8 mix test --max-cases 6`: **12 doctests, 2,027 tests, 0 failures,
  4 excluded**. Database integration tests ran. The existing configuration
  excludes external DNS and PowerShell/Pester tests; `pwsh` is unavailable.
- `mix format` and `git diff --check`: passed.
- `mix precommit`: passed, including compilation with warnings as errors,
  unused-dependency check, Hex audit, formatting, strict Credo and Dialyzer.
  Dialyzer reports **Total errors: 2, Skipped: 2, Unnecessary Skips: 0**,
  matching the existing Gettext filters. No suppressions were added.

## Verdict

Approved with fixes. Claude's follow-up is sound; the additional editor
attribution defect is fixed. Source reconstruction retains the producer-metadata
limitations described above.
