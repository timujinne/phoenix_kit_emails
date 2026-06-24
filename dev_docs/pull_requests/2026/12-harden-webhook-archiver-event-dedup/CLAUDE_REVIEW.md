# Code Review: PR #12 — Harden emails module: webhook security, archiver streaming, event dedup, analytics

**Reviewed:** 2026-06-24
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/12
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 4f4828cf3e161caaf475781dc9974a70a2b9fb2f
**Merge commit:** 938d734e449b26afce80f3a9f69981cfaf847e28
**Status:** Merged

## Summary

Follow-up hardening for the emails module after a multi-dimensional review of
v0.1.7 (608 +/338 −, 14 files, 4 commits). Four themes:

1. **SQS ingestion regressions** — placeholder insert bypasses sampling
   (`Log.create_log/1`); open/click no longer downgrade terminal statuses; the
   Oban poller is collapsed to a single self-healing chain
   (`delete_queued_jobs/0` + always-self-schedule + 30s misconfig backoff);
   Option-1 host-mailer `aws_message_id` recovery.
2. **Webhook security + archiver + analytics** — SNS signing-cert URL locked to
   `sns.<region>.amazonaws.com` + `/SimpleNotificationService-*.pem`;
   `SignatureVersion` honored (SHA-1/SHA-256); `X-Forwarded-For` only trusted
   from configured proxies; `confirm_subscription/1` now issues the GET; CSV
   exports fully escaped (formula injection + RFC 4180); archiver truly streams
   via `Repo.stream`; `list_logs` drops the `[:user, :events]` preload from the
   hot path; `opened_at`/`clicked_at` written; stats query collapsed 7→1; PubSub
   updates a single row.
3. **Resilience hardening** — Option-1 recovery narrowed to `provider == "unknown"`
   + RFC-id rejection; poller self-heals on sustained errors; archiver
   compression wrapped against mapper exceptions.
4. **Event dedup on `occurred_at`** for open/click (multi-occurrence) vs
   one-per-type for single-occurrence events.

**Hard dependency:** core phoenix_kit **1.7.164 + migration V137** (two partial
unique indexes on the events table + `aws_message_id` backfill). The new
`unique_constraint`s are inert no-ops until V137 lands.

## Issues Found

### 1. [BUG - MEDIUM] `mark_as_opened`/`mark_as_clicked` silently lose the status update on a same-second duplicate event (activates with V137) — FIXED
**File:** `lib/phoenix_kit/modules/emails/log.ex` lines 609–633 (`mark_as_opened`),
643–672 (`mark_as_clicked`); `lib/phoenix_kit/modules/emails/event.ex` lines
194–204 (`create_event`)

Both functions wrap an `update_log/2` and an `Event.create_event/1` in a single
`repo().transaction/1`:

```elixir
repo().transaction(fn ->
  {:ok, updated_log} = update_log(email_log, changes)   # status + opened_at/clicked_at
  Event.create_event(%{email_log_uuid: ..., event_type: "open", occurred_at: opened_at})
  updated_log
end)
```

`Event.create_event/1` performs a **plain** `repo().insert(changeset)` (no
`mode: :savepoint`). Once V137 adds the partial unique index on
`(email_log_uuid, event_type, occurred_at)` for open/click, a duplicate event
insert raises a `unique_violation`. Ecto maps the declared `unique_constraint`
to `{:error, changeset}` (→ `{:ok, :duplicate_event}`) **without raising**, but
the *PostgreSQL transaction is already aborted* — Ecto does **not** wrap
constraint operations in a savepoint by default
(`deps/ecto/lib/ecto/repo.ex:2483-2499`). At `COMMIT`, Postgres rolls the
aborted transaction back, so the `update_log` change (status → `opened`/`clicked`,
`opened_at`/`clicked_at`) **is never persisted**, while the caller still receives
a struct as though it succeeded. Silent data loss.

**Reachability (live path, not theoretical):**
`WebhookController.process_email_event/1` → `Emails.process_webhook_event/1` →
`process_event_for_log/2` creates an open/click event in
`Event.create_from_ses_webhook/2` (`occurred_at` = the SNS event timestamp), then
`update_log_status_from_event/2` calls `Log.mark_as_opened/clicked`, which inserts
a **second** open/click event at `occurred_at = UtilsDate.utc_now()`. Crucially,
`occurred_at` is `:utc_datetime` and both `UtilsDate.utc_now/0` and
`SQSProcessor.parse_timestamp/1` truncate to **whole seconds**. For real-time SNS
delivery the event timestamp and the processing second routinely coincide, so the
second insert collides on the unique index and aborts the transaction. (When the
seconds differ, the same path instead stores two open events for one open — a
pre-existing double-count the dedup does not collapse.)

**Why it matters:** open/click status + first-engagement timestamps are silently
dropped on the most common live notification path once the required V137 migration
ships. The SQS path (`SQSProcessor.process_open_event/process_click_event`) is
*not* affected — it calls `Event.create_event` outside any transaction.

**Suggested fix:** make the dedup insert transaction-safe by using a savepoint, so
catching the violation does not poison the surrounding transaction:

```elixir
# event.ex, create_event/1
case repo().insert(changeset, mode: :savepoint) do
```

`mode: :savepoint` is a no-op outside a transaction and a savepoint inside one, so
it is correct for both the transactional (`mark_as_*`) and non-transactional (SQS)
callers. Alternatively, move the `Event.create_event` call out of the
`repo().transaction` in `mark_as_opened`/`mark_as_clicked`.

**Fix applied** (`event.ex`, `create_event/1`): the dedup insert now uses
`repo().insert(changeset, mode: :savepoint)`, scoping a unique-violation rollback
to the failed insert so the caller's transaction (and its preceding status update)
survives. No-op for the non-transactional SQS callers.

**Confidence:** 80/100 (mechanism certain; impact gated on V137 being live + a
same-second collision, which second-precision timestamps make common).

### 2. [BUG - LOW] `get_stats_for_period` counts a status string that is never written (`"complained"`) — FIXED
**File:** `lib/phoenix_kit/modules/emails/log.ex` line 814

The collapsed stats query counts complaints with
`count(fragment("CASE WHEN ? = 'complained' THEN 1 END", l.status))`. The
canonical status value is **`"complaint"`** — it is the only complaint status in
the `validate_inclusion` set (`log.ex:285`) and the only one ever written
(`sqs_processor.ex:498` `status: "complaint"`). Nothing in the codebase sets
`"complained"`. So the `complained` metric is **always 0**.

This is a pre-existing bug, but the PR rewrote this exact query (7 aggregates → 1)
and carried the wrong literal forward verbatim — a good opportunity to fix it.
(Related, out of PR scope: `archiver.ex:323` and `archiver.ex:564` use the same
`"complained"` string in do-not-archive exclusion lists, so emails with the real
`"complaint"` status are *not* protected from compression/S3 archival.)

**Suggested fix:** change the literal to `'complaint'` (and align the archiver
exclusions in a follow-up).

**Fix applied** (`log.ex:814`): the `complained` count now matches against
`'complaint'`. The archiver exclusion-list mismatch (`archiver.ex:323`, `:564`) is
left for a separate follow-up as it is outside this PR's scope.

**Confidence:** 95/100.

### 3. [OBSERVATION] `:httpc` fetches do not verify the TLS server certificate
**File:** `lib/phoenix_kit/modules/emails/web/webhook_controller.ex`
(`fetch_certificate_http/1`, and the new `http_get_status/1`)

Both call `:httpc.request(:get, {url, []}, [{:timeout, 10_000}], [])` with no
`ssl:` options. Erlang's `:httpc` does not verify the peer certificate unless
`ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), ...]` is passed.
The host is now correctly locked to `sns.<region>.amazonaws.com` (blocks SSRF and
attacker-hosted certs on arbitrary `*.amazonaws.com`), but an **active**
network MITM could still substitute the signing certificate fetched for signature
verification and forge a valid-looking signature. The cert-fetch path is the
security-relevant one; `http_get_status` (subscription confirm) is lower risk.

The unverified-fetch pattern predates this PR; the PR extends it. Recommend adding
`verify_peer` with the system CA store. Not a merge blocker.

**Confidence:** 70/100 (depends on the OTP default in the deploy target).

### 4. [NITPICK] `get_remote_ip/1` re-reads Settings per forwarded-IP element
**File:** `lib/phoenix_kit/modules/emails/web/webhook_controller.ex`
(`get_remote_ip/1`)

`Enum.find(..., &(&1 not in trusted_proxies()))` calls `trusted_proxies/0` — which
reads `Settings.get_setting("webhook_trusted_proxies", "")` and splits it — once
per element of the forwarded chain. Hoist it to a local binding (it is already
computed once for the `peer_ip in trusted_proxies()` guard).

### 5. [OBSERVATION] SNS host regex excludes AWS China endpoints
**File:** `lib/phoenix_kit/modules/emails/web/webhook_controller.ex`
(`@sns_host_regex ~r/^sns\.[a-z0-9-]+\.amazonaws\.com$/`)

The `$` anchor after `.amazonaws.com` rejects China-partition hosts such as
`sns.cn-north-1.amazonaws.com.cn`. If this module is ever deployed against AWS
China, signature verification and subscription confirmation will fail closed.
Acceptable for the current target; worth noting for portability.

## What Was Done Well

- **SQS poller single-chain resilience** (commits 1 & 3): the reasoning that
  exactly one mechanism (self-schedule vs Oban retry) must own continuation, the
  `delete_queued_jobs/0` collapse of stale duplicate chains, the always-self-schedule
  + 30s misconfig backoff so a sustained outage cannot permanently kill polling,
  and `yield_many` + `shutdown` instead of `await_many` (no batch abort on a slow
  task) are all correct and well-commented. The `:executing`-excluded `unique`
  window backstop reasoning is sound.
- **Archiver streaming** (`stream_in_batches/3`): `Repo.stream` inside a
  transaction with `max_rows: batch_size` is the right fix for the OOM /
  only-first-batch-compressed bug, and dropping the premature `limit/2` is
  correct. The `rescue → {0, 0}` wrapper mirrors `process_s3_archival`.
- **Webhook signature hardening**: cert-URL host+path lockdown and
  `SignatureVersion`→digest mapping (`:sha`/`:sha256`, unknown ⇒ `:error`) are
  genuine, fail-closed security improvements. Reading the digest early in the
  `with` is correct.
- **CSV export**: routing every cell through `escape_csv_field/1` via
  `format_csv_row/1` both closes the formula-injection hole and fixes a latent
  delimiter-breakage bug (a subject containing `,` previously produced malformed
  CSV — cells were not RFC 4180 quoted in the old `to_string`-only join). Escaping
  is applied exactly once.
- **Interceptor Option-1 recovery** correctly narrowed to `provider == "unknown"`
  and rejects RFC angle-bracket ids (`<`, `>`, `@`), so Local/SMTP/Test sends are
  no longer misclassified as `aws_ses`.
- **Event dedup design**: declaring both unique_constraints with `:email_log_uuid`
  first so a single `duplicate_event_error?/1` detector covers either violation is
  a clean touch, and the `:unique`-vs-`:foreign_key` discrimination avoids
  confusing FK errors with dedup.
- Removing the unindexed JSONB `headers` OR-scan from the hot `aws_message_id`
  lookup, the per-write SELECT uniqueness check, dead `get_placeholder_stats/0`,
  and the per-event full-list reload (single-row PubSub update) are all good
  hot-path cleanups, and the previously-silent `rate_limiter` rescue branches now
  log.

## Validation

Gate on the merged baseline (`mix compile --warnings-as-errors`, `mix format
--check-formatted`, `mix credo --strict`): **all clean** — no warnings, formatted,
credo found no issues across 37 files. Dialyzer not re-run for a review-only pass.
None of the findings above are compile/credo-visible (they are runtime/semantic).

## Verdict

**Approved with fixes (applied).** The PR is a high-quality, well-reasoned
hardening pass and is safe as merged (the dedup constraints are inert until V137).
Issues #1 (silent status-update loss on the live SNS open/click path, fixed with
`mode: :savepoint`) and #2 (`'complaint'` literal) were fixed in follow-up commit
on top of the merge; the gate (`compile --warnings-as-errors`, `format`, `credo
--strict`) remains clean after the fixes. Issues #3–#5 are hardening/portability
notes left for follow-up, not blockers.
