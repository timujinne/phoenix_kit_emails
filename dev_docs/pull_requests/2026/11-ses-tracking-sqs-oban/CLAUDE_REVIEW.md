# Code Review: PR #11 — Fix SES delivery-event tracking and consolidate SQS polling to Oban

**Reviewed:** 2026-06-23
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/11
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 528eadf34f5f154e24d6d84e3bc7825348b58ec5
**Status:** Merged (reviewed post-merge)

## Summary

Two themes in one PR:

1. **Consolidate SQS polling onto Oban.** Deletes the 842-line GenServer
   `SQSWorker` entirely. `SQSPollingJob` (Oban) becomes the sole poller; the
   `Supervisor` no longer owns a long-running polling child — it just kicks off
   the first Oban job at boot and `SQSPollingManager` is the single runtime
   control surface (enable/disable/status, wired to the admin toggle).
2. **Fix SES delivery-event tracking.** Provider detection now classifies a
   message as `aws_ses` when a configuration set is configured (covers the
   "host app uses its own Swoosh mailer" case). `delete_message/3` stops
   swallowing failures as `:ok`, and reads both string and atom receipt-handle
   keys, fixing messages that re-cycled forever. Status changes broadcast over
   PubSub so the admin emails list live-updates without a reload.

Plus the self-scheduling/unique-states fix (`:executing` excluded so the
self-reschedule chain doesn't stall) and the settings-toggle fix (route through
`SQSPollingManager` so polling starts at runtime, not next boot).

## Issues Found

### 1. [BUG - HIGH] `unique` states list fails the `--warnings-as-errors` build — FIXED
**File:** `lib/phoenix_kit/modules/emails/sqs_polling_job.ex` (worker `unique:` opt)

Under Oban 2.23 (bumped post-merge in `a323f87 lib upgrades`),
`Oban.Job.warn_unique/1` emits a compile-time warning for **any** custom
`states` list that omits incomplete states — here `[:scheduled, :available]` is
missing `[:suspended, :executing, :retryable]`:

```
warning: unique :states [:scheduled, :available] is missing incomplete states
[:suspended, :executing, :retryable] which may break uniqueness,
use a unique group like :incomplete
```

The repo's gate (`precommit` → `compile --force --warnings-as-errors`,
`quality.ci`) turns that warning into a build failure, so the merged tree does
**not** pass its own precommit. The suggested `:incomplete` group is wrong here —
it *includes* `:executing` and would reintroduce the self-scheduling stall the
author just fixed.

**Fix:** narrowed to `unique: [period: 10, states: [:scheduled]]`. This is
exactly sufficient and warning-free:
- Self-scheduled jobs always land in `:scheduled` (interval ≥ 1000ms ⇒
  `schedule_in` ≥ 1s; never `:available`), so the self-reschedule chain is still
  deduped.
- The immediate (`:available`) job from `enable_polling/0` is already coalesced
  there by `cancel_scheduled()` before insert, so dropping `:available` from the
  unique list loses no real protection (only a harmless, idempotent transient on
  a `poll_now/0` double-click, which the queue's concurrency-1 cap serialises).
- `[:scheduled]` is the one list form Oban explicitly special-cases as
  non-warning.

The detailed comment was updated to explain the new state set.
**Confidence:** 95/100

### 2. [BUG - MEDIUM] New PubSub broadcast helper fails `credo --strict` — FIXED
**File:** `lib/phoenix_kit/modules/emails/log.ex:534`

`maybe_broadcast_status_change/2` calls
`PhoenixKit.Modules.Emails.email_status_topic()` — a deeply-nested,
fully-qualified call that `Credo.Check.Readability.AliasUsage` flags;
`mix credo --strict` (part of `quality.ci`/`precommit`) then exits non-zero.

**Fix:** added `alias PhoenixKit.Modules.Emails` and call
`Emails.email_status_topic()`.
**Confidence:** 100/100

### 3. [NITPICK] Configuration-set dedup is incomplete for the nil / invalid case
**File:** `lib/phoenix_kit/modules/emails/interceptor.ex`
(`extract_email_data/2` + `get_configuration_set/1`)

`extract_email_data/2` resolves the configuration set once and stuffs it into
`opts` so `detect_provider/2` won't repeat the settings lookup (and the
validation warning). But `get_configuration_set/1` does:

```elixir
Keyword.get(opts, :configuration_set) || Emails.get_ses_configuration_set()
```

When the resolved value is `nil` — i.e. *no* config set, **or** a configured set
that failed validation — the `||` falls through and re-runs the settings lookup,
re-emitting the validation warning in the invalid case. So the stated benefit
holds only for a valid, non-nil set; the misconfiguration case the comment most
wants to protect still double-looks-up and double-warns.

**Not fixed (deliberate).** The clean fix changes `get_configuration_set/1` to
distinguish "key present" from "key absent" (`Keyword.has_key?`), altering the
contract of a shared helper that `build_ses_headers/2` and the public
`detect_provider/2` also call. The cost of leaving it is one extra settings read
plus one extra log line in a misconfiguration edge case — not worth the
contract-change / over-engineering risk. Recorded here so the limitation is on
file.
**Confidence:** 80/100

### 4. [OBSERVATION] Stale `mix.lock` entry (`earmark`) — FIXED (pre-existing, not PR #11)
`earmark` (the full, now-retired package — only `earmark_parser` is actually
used) lingered in `mix.lock`, failing both `deps.unlock --check-unused` and
`hex.audit` (both in `precommit`) and blocking a clean release. Not introduced by
PR #11; surfaced while running the release gate. Removed via
`mix deps.unlock earmark`.
**Confidence:** 100/100

### 5. [OBSERVATION] Doc drift — deleted `sqs_worker.ex` still listed — FIXED
The PR rewrote the AGENTS.md "SQS Pipeline" narrative but the File Layout tree in
`AGENTS.md` and the layout in `README.md` still listed the now-deleted
`sqs_worker.ex`. Removed both entries.
**Confidence:** 100/100

## What Was Done Well

- **The `:executing`-exclusion reasoning is exactly right** and superbly
  documented: including `:executing` would dedup the self-reschedule against the
  still-running job (chain stalls), and a job orphaned in `:executing` by a hard
  crash would permanently block every future insert. This was the actual root
  cause of the polling stalls.
- **`delete_message/3` no longer lies.** Returning `{:error, _}` instead of `:ok`
  means a message that wasn't deleted isn't counted as processed; the dedicated
  `nil`-receipt-handle clause + reading both `"ReceiptHandle"` and
  `:receipt_handle` fixes the "re-received forever" bug at the source.
- **`enable_polling/0` cancel-then-insert-one** correctly guarantees a live chain
  on the off→on toggle and reasons through Oban's unique-collapse rather than a
  fragile "is a job already executing?" guard that could leave no chain.
- **Best-effort broadcast done properly.** `maybe_broadcast_status_change/2`
  broadcasts only on a real status change (through the `update_log/2` chokepoint,
  so header-only/no-op writes don't storm), and is wrapped in `rescue`/`catch` so
  PubSub can never break the DB write. The LiveView guards on `connected?`, only
  reloads when the changed row is on-screen, and intentionally skips the 30-day
  stats recompute — no query storm.
- **The settings-toggle fix is the right one** — routing through the manager so
  the poller actually starts/stops at runtime instead of silently waiting for the
  next boot.
- **Clean GenServer removal** — 842 lines gone with no dangling code references.

## Verification (local, post-merge + fixes)

- `mix compile --force --warnings-as-errors` — clean (after fix #1).
- `mix format --check-formatted` — clean.
- `mix credo --strict` — 0 issues (after fix #2).
- `mix deps.unlock --check-unused` — clean (after fix #4).
- `mix hex.audit` — no retired packages (after fix #4).
- `mix dialyzer` — see release notes / commit.

## Verdict

**Approved with fixes.** The logic is sound and unusually well-reasoned — the two
blocking problems were gate failures (red build, red lint), not behavioural bugs,
and both are fixed. A pre-existing stale-lock entry was also cleaned up so the
release gate is green. One documented nitpick (config-set dedup) left in place by
choice.
