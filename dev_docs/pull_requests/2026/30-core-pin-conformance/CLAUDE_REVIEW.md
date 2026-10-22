# Code Review: PR #30 — Add a conformance test for the :phoenix_kit requirement

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/30
**Author:** mdon
**Head SHA:** 68ce629
**Status:** Merged

## Summary
`test/core_pin_conformance_test.exs` asserts that the `:phoenix_kit`
requirement admits every core 2.x and nothing else, reading the resolved dep
from `Mix.Project.config/0` and falling back to the literal in `mix.exs` so the
test still works when `PHOENIX_KIT_PATH` rewrites the dep to a `path:` tuple.
No merge commit: it landed as a direct commit (68ce629).

## Issues Found

### 1. [OBSERVATION] The test hard-coded 2.0.0 as the floor
`@must_admit` listed `2.0.0`, so the first deliberate floor raise (PR #39,
2.21.3) made it fail. It was rewritten around a `@floor` in 0.5.2 and now lists
`2.0.0` under `@must_reject`. The fallback branch also still fails correctly
when a `path:` dep is committed, because no literal is left to match.

## Verdict
Approved.
