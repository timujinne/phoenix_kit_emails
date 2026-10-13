# 0.5.5 review handoff to Claude

The follow-up review fixes five additional defects after Claude's local
`ba5d89e` release-preparation commit. Version 0.5.5 and Claude's translation
fix are retained. The fixes and review notes are committed locally on main;
pushing, tagging and publishing remain for the release step.

## Changes to inspect

- Preserve translations for locales omitted by the editor form during both
  validation and saving. Explicitly empty submitted values still remove a
  translation; context callers still replace entire translation maps.
- Rebuild the changeset, preview variables, title and version subtitle from
  the saved row after an update.
- Initialize new templates with starter bodies in the selected locale.
- Reject non-text optional description translations in the schema changeset.
- Show default-source badges only for catalog entries declaring content
  defaults or a defaults callback; do not execute callbacks during the scan.

Each fix has a regression test that failed before the implementation change.
The 0.5.5 changelog includes the fixes. Gettext catalogs were refreshed for the
changed source references without adding new message IDs.

## Validation

- `PGPOOL=8 mix test --max-cases 6`: 1,147 tests, 12 doctests, zero failures;
  the database integration tests ran.
- `mix precommit`: passed, including compilation with warnings as errors,
  unused dependency checking, Hex audit, formatting, strict Credo and Dialyzer.
  The existing Gettext/Expo opaque-type filter covers the same two Dialyzer
  warnings; no filter was added or broadened.
- `mix gettext.extract --check-up-to-date`: passed after refreshing catalogs.
- `git diff --check`: passed.

The Hex audit reported that the authentication session expired. Authenticate
with `mix hex.user auth` before publishing; audit itself succeeded and found
no retired packages or security advisories.

## Release continuation

Inspect the local follow-up commit together with `ba5d89e`. Push main and verify
the remote commit before any release tag. Keep version 0.5.5; these fixes belong
to that unpublished release. Follow the repository's bare version tag convention
and use the 0.5.5 changelog section for GitHub release notes. Hosts still need
`mix phoenix_kit.update` for migration V3.

## Review files

- [PR #53](../53-escape-vars/CODEX_REVIEW.md)
- [PR #54](../54-editor-save/CODEX_REVIEW.md)
- [PR #55](../55-editor-preview/CODEX_REVIEW.md)
- [PR #56](../56-usage-count/CODEX_REVIEW.md)
- [PR #57](CODEX_REVIEW.md)
