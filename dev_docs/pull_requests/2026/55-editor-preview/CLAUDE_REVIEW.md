# Code Review: PR #55 — Fix the editor preview showing raw placeholders and going stale, and translate its labels

**Reviewed:** 2026-10-13
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/55
**Author:** timujinne
**Head SHA:** 8f66e62
**Status:** Merged

## Summary
The preview is built from the changeset (`apply_changes`) with sample values
for every variable, so it follows what is typed. Page title, subtitle, category
/ status / source labels and the variable hints are translated. Variable hints
are now placeholders and are no longer written into the stored description.

## Issues Found
None. `preview/2` goes through `Template.substitute_variables/3`, so it shows
the same escaping a real send does, and sample values are strings, so the new
non-scalar `ArgumentError` cannot fire from it.

### 1. [OBSERVATION] Rows saved by the old editor keep their English hints
Descriptions the previous version stored (`"User's display name"`) stay as the
author's text. Not worth a migration.

## Verdict
Approved.
