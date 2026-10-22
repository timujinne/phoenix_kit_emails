# Code Review: PR #39 — Point the Amazon SES integration links at the renamed route

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/39
**Author:** timujinne
**Head SHA:** fb5a999
**Status:** Merged

## Summary
Both Settings -> Integrations links in the SES/SQS section move from
`/admin/settings/integrations/website` to `/admin/settings/integrations`, and
the core floor becomes `>= 2.21.3 and < 3.0.0` (written as a range because a
three-segment `~>` would cap at 2.22).

## Issues Found

### 1. [OBSERVATION] The PR left the conformance test red
`core_pin_conformance_test.exs` still listed 2.0.0 as a version that must be
admitted, so the suite failed on the merge commit. Fixed afterwards in 0.5.2.

### 2. [NITPICK] Path still hard-coded
AGENTS.md says to use `Paths` helpers, not literal paths. The link is written
as a literal in two places in the template; a `Paths.integrations/0` would have
made the next rename a one-line change. The route is core's, not this module's,
which is the reason it was probably left.

### 3. [OBSERVATION] A link fix raised a hard dependency floor
Every host on core < 2.21.3 is now locked out of new releases of this module
for the sake of two hyperlinks. The comment in `mix.exs` explains why (the old
path matches core's `:uuid` edit route with `uuid = "website"` and loops in a
400 reload), so the trade is made knowingly.

## Verdict
Approved.
