# Code Review: PR #58 — SMTP verification and Claude's follow-up

**Reviewed:** 2026-10-23

**Reviewer:** Codex (GPT-6)

**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/58

**Status:** Merged; follow-up `1a7f07a` rechecked

## Scope

Reviewed the SMTP claim path, settings events, scope relay, built-in SMTP connector,
and Claude's production-code changes in `1a7f07a`. This is a focused follow-up,
not a claim to have re-audited all 114 files in #58. Recent template PRs #53–#57
already have Codex reviews and are covered by the full regression suite.

Claude's public-address filtering and parked-item index are useful fixes. The
connector resolves once and connects to the checked IP, which prevents a second
DNS answer bypassing the filter. The partial index matches address-based queries
for `awaiting_smtp` items. No migration version bump is needed for these unreleased
V5 statements.

## Findings

### [BUG - MEDIUM] Stale or missing identity could mutate SMTP settings — FIXED

`set_mode`, local confirmation, `save`, and `clear_pause` did not re-read rights.
A deactivated user or someone whose `emails` permission was revoked could still
use an already-open page to change mode, sender settings, or resume a paused runner.
Claude noted this as an observation; these are persistent, operational changes.

These events now require `emails` in the page's scope and a fresh scope from an
active user. Settings use the existing Auth/Scope APIs, so local mode remains
available on older cores and to email administrators without API permission.
Core's `PhoenixKit.API.Access.fresh_scope/1` specifically requires **api** and
cannot be used as the email-settings authorization check. Token and machine-API
operations retain that separate requirement.

The off mode previously had no scope lookup because it had no runner relay.
Added a one-shot lookup with no timer or runner subscription, and keep the mode
radios disabled until scope is available. The real LiveView test verifies the
initially-off section can learn its user and enable the runner. Tests also cover
missing identity, permission revocation, deactivation between request and local
confirmation, and an administrator with `emails` but without `api`. Checking
fresh rights does not replace the page's selected-role scope with the union of
all roles: a regression test ensures a settings change cannot unlock API actions
from an unselected role.

### [BUG - MEDIUM] DNS failures could starve every later domain — FIXED

`candidate_domains/2` considers only the oldest `max_sessions * 3` domains.
Transient DNS failures left their rows immediately due, so each claim could
select the same failures indefinitely, never reaching healthy domains behind them.
This is queue starvation, not merely a slow resolver.

Skipped DNS domains now wait 60 seconds through `not_before`, and candidate
ordering uses the earliest due time (`not_before`, falling back to `inserted_at`).
A failed lookup therefore stays behind untouched work even after its delay expires;
a delay alone could still starve a large backlog when old retries became due.
They keep their
queue rows, verdicts, lease history and SMTP retry counters. The same deferral
also moves domains skipped after exhaustion of the claim DNS budget out of the
candidate window temporarily. The regression test failed before the fix: after
three failing domains filled the window, the second claim still could not reach
the healthy fourth domain. It now advances past the retry delay before asking
for the healthy domain, and also checks that a deferred domain can recover.

### [BUG - MEDIUM] Claude's DNS check escaped the SMTP connection deadline — FIXED

The added `:inet.getaddrs/2` uses an infinite lookup timeout (verified against the
installed OTP `inet.erl`). The socket still received the entire original timeout
after DNS finished. The lookup could therefore outlive both the configured
connection timeout and the session time remaining.

Use `:inet.getaddrs/3` with the remaining connection budget, then subtract lookup
time before opening the socket. An exhausted budget opens no socket. Existing
connector tests cover the hard deadline, expired-before-connect behavior, public
address filtering, private-address refusal and the shared SMTP dialogue vectors.
A stalled OS resolver is not simulated by these tests.

### [TEST - LOW] API test teardown could race PubSub supervisor shutdown — FIXED

Focused and full-suite runs exposed `already started` failures in the API and
batch fixtures. Core's PubSub manager links its supervisor indirectly and can
exit before the named supervisor finishes. These fixtures now supervise the
`Phoenix.PubSub` tree directly, which supplies the same broadcast/subscription
service and makes teardown wait for the entire tree. All four verification
test modules that used this startup pattern use direct supervision too.

## Retained limitations

The PowerShell runner still lacks the local connector's public-address filter.
Its script and protocol are unchanged in this follow-up. PowerShell/Pester are
unavailable here, so script execution is not validated. This remains the network
reachability limitation Claude documented, and should be addressed in a separate
script change with matching protocol versions and executable Pester coverage.
The old unrouted settings LiveView remains for compatibility; its missing SES
control is resolved in the reachable settings section (see the #6 review).

## Validation

- `PGPOOL=8 mix test --max-cases 6`: **12 doctests, 1,977 tests, 0 failures,
  4 excluded**. Integration tests used the test database; external DNS and
  PowerShell/Pester cases were excluded by the existing suite configuration.
- The initial precommit stopped in Hex audit on `plug_crypto` 2.2.0. Updated only
  that lockfile entry to compatible patch 2.2.1; Hex audit and Credo now pass.
- Final `mix precommit`: **passed** (compile with warnings as errors, unused-lock
  check, Hex audit, formatting, strict Credo and Dialyzer). Dialyzer reports
  **Total errors: 2, Skipped: 2, Unnecessary Skips: 0**: exactly the existing
  Gettext-generated `call_without_opaque` warnings. No filters or suppressions
  were added. Core's inferred permission-set type is normalized through public
  Enumerable/MapSet APIs at the scope boundary instead.
- Re-ran the entire suite after the final scope/type changes: the same
  **12 doctests, 1,977 tests, 0 failures, 4 excluded** result.
