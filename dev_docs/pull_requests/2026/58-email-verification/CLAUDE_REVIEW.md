# Code Review: PR #58 — Add address verification with an optional SMTP stage through a remote runner

**Reviewed:** 2026-10-21
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/58
**Author:** timujinne
**Head SHA:** 62ef3ae
**Status:** Merged

## Summary
114 files, about 39k lines, of which roughly 11k are word lists, 9k tests and 1.2k
the PowerShell runner. The rest is a verification engine: normaliser, syntax/flag
checks, DNS MX (`Resolver`, `Hijack`), a cache of domain facts, batches with
Oban workers, and an optional SMTP stage that runs either through a remote
PowerShell runner (core's machine API, scope `emails.smtp_runner:run`) or from
the server itself (`Smtp.Direct`, mode `local`). Migration chain V4 (four
tables) and V5 (SMTP queue, runners, `awaiting_smtp`). Neither is released
yet: 0.5.5 shipped on 2026-10-13 with V3.

I read in full: `smtp/direct.ex`, `smtp_queue.ex`, `classifier.ex`,
`runner_api.ex`, `runner_keys.ex`, `local_runner.ex` and its worker,
`verify_email_worker.ex`, the settings section's event handlers, the V4/V5
migration diff, and the runner script's TLS/token handling. `batches.ex`,
`config.ex`, `pipeline.ex`, `resolver.ex`, `domain_cache.ex` and
`smtp_settings.ex` I read only where the above called into them.
I could not run the Pester suite (`pwsh` is not installed here; the ExUnit
wrapper skips with a printed reason), so the script itself is reviewed by
reading, not by execution.

## Issues Found

### 1. [BUG - MEDIUM] Mode `local` dialled whatever an MX record named — FIXED
**File:** `lib/phoenix_kit/modules/emails/verification/smtp/direct.ex` (`connect/3`)
The only filter on an MX target was "must be a host name, not an IP literal".
`localhost`, or any name whose A record is `127.x`, `10.x`, `169.254.169.254`,
and so on, passed. The domain belongs to whoever typed the address (a signup
form that verifies addresses is enough), so they could make the server open
port 25 on its own loopback or internal network, run `EHLO`/`MAIL FROM`/`RCPT
TO` there, and have the `RCPT` reply (cut to 200 characters) stored in that
address's verification log, readable wherever the host app shows the log. It is port 25 only and `DATA` is
never sent, which is why this is MEDIUM and not HIGH, but it is still a way
to probe an internal mail relay and read its banner.
**Fix:** for sessions the host name is resolved in `Direct` and the socket is
opened to the first *public* IPv4 address that came back, not to the name, so
a second lookup cannot answer differently. Loopback, RFC 1918, CGNAT,
link-local, documentation, benchmarking, multicast and reserved space are
refused and the attempt ends as `connect_failed`. The port 25 self-test host
is chosen by the admin and keeps the old path. The test config's own
loopback-only guard is unchanged and still skips the lookup.
Tests: `public_address?/1` over both sides of every range boundary;
`direct_public_only_test.exs` (`async: false`, flips the guard off and restores
it) shows that a host resolving to 127.0.0.1 gets no connection. I checked the
test fails with the fix reverted.
**Confidence:** 90/100

### 2. [IMPROVEMENT - MEDIUM] Batch items were looked up by address with no usable index — FIXED
**File:** `lib/phoenix_kit/modules/emails/migrations.ex` (V5)
`Batches.settle_awaiting/2` and `lock_awaiting/1` find parked items with
`WHERE email = ? AND state = 'awaiting_smtp'`. The only indexes on
`batch_items` lead with `batch_uuid`, so every settled address in a report
scanned the whole table (batches go up to 100k addresses and are never
pruned). A report of 50 results with a few batches of history is hundreds of
thousands of rows per claim/report call, and these calls are HTTP requests
with a rate limit.
**Fix:** a partial index `batch_items (email) WHERE state = 'awaiting_smtp'`,
version 5 in the existing statement list. V5 has not shipped, so no new chain
version is needed; a host that already ran V5 from a pre-release gets it on the
next `mix phoenix_kit.update` because every statement is `IF NOT EXISTS`.
Test: the statement is present, partial, and absent below V5.
**Confidence:** 85/100

### 3. [OBSERVATION] The PowerShell runner has the same reach, left alone
The runner dials the MX hosts from the runner machine's network. The server
cannot decide that for it by looking at names, and a check in the script means
a protocol bump of `$RunnerVersion` and a Pester run, which I cannot do here.
It is a smaller exposure (the runner is an operator's own machine, and it only
reports reply codes back) but the same class. Suggested follow-up: refuse
non-public resolved addresses in `Invoke-SmtpSession`, bump both version
constants together, add a vector.

### 4. [OBSERVATION] Claim can starve behind domains it keeps skipping
`candidate_domains/2` takes the oldest `max_sessions * 3` domains and
`lease_domain/4` skips one on a transient DNS failure without touching its
rows, so the same oldest domains head the list on every claim. Sixty
persistently unresolvable domains at the front would keep the rest waiting
until `email_verify_smtp_queue_max_age_h` (48 h) settles them. Not a
correctness problem and it needs a resolver outage, so left as is; an offset
by last-attempt time would fix it.

### 5. [OBSERVATION] Settings events do not re-read rights
`set_mode`, `save` and `clear_pause` act on the page's session rights;
only the token and machine-API events call `PhoenixKit.API.Access.fresh_scope/1`.
An admin who loses the `emails` permission while the page is open can still
switch the mode to `local` until that LiveView reconnects. The token actions
are the ones that matter for a stolen session, and they do re-read.

### 6. [OBSERVATION] Bundled lists
AGENTS.md says never to commit third-party lists. `disposable.txt` is the
disposable-email-domains list, CC0 1.0, with source, licence, date and counts
in `SOURCES.md`; `tlds.txt` is IANA's. Neither is the non-redistributable
LetsExtract/Kellerman set, which the loader only reads from an external
directory. Fine, but the refresh is manual until the scheduled one lands.

## What Was Done Well
- `DATA` can never be sent: the dialogue has no such phase, the address regex
  uses `\z` and a character class with no whitespace, and `no_network_test.exs`
  pins `smtp/direct.ex` as the only file with a socket and `LocalRunner` as its
  only caller.
- The queue's concurrency story holds up under reading: one advisory lock per
  domain around claim, `FOR UPDATE SKIP LOCKED` on rows, batch rows locked in
  uuid order before any settling transaction, a lease token that is spent by a
  report and kept by an expiry so a late report is still taken.
- A reporting runner can only touch rows with its own `lease_token` and
  `leased_by`; an invalid entry rejects that result, not the call.
- The classifier is pure and its table matches the moduledoc, including the
  5.7.x-is-a-block rule that stops a sender-side refusal from marking a good
  mailbox invalid.
- Job args carry uuids, not addresses, and error logs mask the local part.

## Verdict
Approved with fixes — the engine is carefully built and thoroughly tested;
the two defects above are fixed here with tests. The runner-script follow-up
(#3) is the one thing I would do before recommending runner mode on a network
that has internal mail hosts.
