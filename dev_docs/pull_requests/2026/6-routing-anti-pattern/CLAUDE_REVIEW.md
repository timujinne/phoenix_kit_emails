# Code Review: PR #6 — Fix wrong "In your Phoenix router" moduledoc examples

**Reviewed:** 2026-10-22
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/6
**Author:** Dmitri Don (mdon)
**Head SHA:** fe01064
**Status:** Merged

## Summary
Docs only. Six admin LiveView moduledocs (`Blocklist`, `Details`, `Emails`,
`Metrics`, `Queue`, `Templates`) told readers to add a `live "/email-..."` line to
their own router, naming modules (`PhoenixKitWeb.Live.Modules.Emails.*Live`) that
no longer exist. The PR replaces that with a note that the route is generated from
`admin_tabs/0`, fixes the `Details` path, and points `AGENTS.md` at core's
`custom-admin-pages.md`. The existing `PINCER_REVIEW.md` describes only the
`AGENTS.md` line, not the moduledoc changes.

## Verification
Each documented path was checked against `admin_tabs/0` in `emails.ex`:
`emails/dashboard`, `emails`, `emails/email/:id`, `emails/templates`,
`emails/queue`, `emails/blocklist` all match, including the corrected
`emails/email/:id`. `phoenix_kit/guides/custom-admin-pages.md` exists, and
`live_session :phoenix_kit_admin` is the name core's `Routes` uses.

## Issues Found
### 1. [NITPICK] `Web.EmailTracking` moduledoc still claims a route that does not exist — FIXED
**File:** `lib/phoenix_kit/modules/emails/web/email_tracking.ex` lines 15-20
The PR swept the stale routing text but missed this file. It said the LiveView is
"mounted at `{prefix}/admin/settings/email-tracking`". It is in neither
`admin_tabs/0` nor `settings_tabs/0` (which returns `[]`), and nothing in core
registers that path, so the page is unreachable. The module's own test says as
much ("no longer in `admin_tabs/0`"). Moduledoc now says it has no route and
points to the settings section that replaced it.
**Confidence:** 95/100

### 2. [OBSERVATION] An unrouted LiveView is still maintained
`Web.EmailTracking` is still the only UI that writes `email_ses_events`
directly (`EventTracker` and `SQSPollingManager` docs refer to it as "the Email
Tracking page"), yet no operator can open it. Either the toggle belongs in
`Web.SettingsSections.EmailTracking` or the LiveView should go. That is a product
decision, so it is not changed here.
**Confidence:** 80/100

## What Was Done Well
Replacing the wrong snippet with a "do not declare this route" note, rather than
just deleting it, addresses the failure the snippet would have caused: a
hand-registered route outside `live_session :phoenix_kit_admin`.

## Verdict
Approved with fixes — correct and verified; one missed file fixed, one open
question recorded.
