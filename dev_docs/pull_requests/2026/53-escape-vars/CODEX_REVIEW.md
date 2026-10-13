# Code Review: PR #53 — Escape template variables in html_body and parse placeholders once

**Reviewed:** 2026-10-13
**Reviewer:** Codex (GPT-6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/53
**Author:** Timujeen (timujinne)
**Head SHA:** ab4eb2e4d44182c3a68f03a9841b83784e13605c
**Status:** Merged

## Summary

Checked the shared placeholder parser, HTML escaping, raw billing variables,
export compatibility and migration V3 against the installed dependencies.

## Issues Found

No additional defects found. V3 freezes its variable names and rewrites only
matching HTML locale values. The renderer preserves compatibility before V3
runs, and the export lowers the known raw placeholders for older file renderers.

## What Was Done Well

Extraction, substitution and export share the parser. Substitution does not
rescan values, and invalid values raise an error without exposing their contents.

## Verdict

Approved. Hosts must run `mix phoenix_kit.update` for V3; the README and 0.5.5
changelog already include that instruction. The final full suite includes the
V3 database and substitution tests.
