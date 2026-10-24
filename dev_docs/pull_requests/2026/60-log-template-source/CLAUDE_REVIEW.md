# Code Review: PR #60 — Record which template layer built each email in the log

**Reviewed:** 2026-10-24
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/60
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 4c479cb
**Status:** Merged

## Summary
Adds two nullable columns to `phoenix_kit_email_logs`: `template_uuid` and
`template_source` (`"db"` / `"file"` / `"module"`). They come from migration V6,
which adds columns to a table this module already owns, with no FK and no
default. The interceptor stamps both on every log. When the caller names the
layer, it takes that value. Otherwise `TemplateSources.origin/3` works it out
from the template name, checking in core's resolution order: an active row,
then a host file override for the message's locale, then a catalog default.
The details page shows a badge, plus an "Open template" link while the row
still exists. The provider's test send and the template editor's test send
now state their layer explicitly.

The resolution order is correct. Core's `Content.resolve_with_sources/5` uses
an active row whenever one exists. On `send_from_template`, core passes
`template_uuid` exactly when it used a row (`put_db_template_opts/2`), so the
name lookup only runs when core used no row.

## Issues Found

### 1. [BUG - MEDIUM] Core's auth mails never got a layer — FIXED
**File:** `lib/phoenix_kit/modules/emails/interceptor.ex` (`template_origin/2`)

`UserNotifier.deliver_built/1` sends every auth mail (welcome, magic link,
confirm, reset password, organization invitation) with
`template_name: "user_notification"`. Content is resolved under the real name
(`"magic_link"`, …), but that name never leaves core. Looking up
`"user_notification"` finds no row, file or catalog entry, so these logs always
got `template_source: nil`. That held even when an admin-edited DB row built
the message, and auth mail is the most common case the feature was meant to
show. A host that created a row actually named `user_notification` would have
been mislabelled `"db"` with the wrong uuid.

Core does keep the direct evidence: `build_templated/5` puts the row it used
(or `nil`) into `email.private[:phoenix_kit_db_template]`. That private map
reaches `intercept_before_send/2` unchanged.

**Fix:** a new `private_origin/1` runs before the name lookup:
- If the key holds a template, the result is `{"db", uuid}`.
- If the key is present but `nil`, the result is `{nil, nil}`. The logged name
  is not the name the content was resolved under, so looking it up would only
  produce false evidence.

The `file`/`module` distinction stays unknown for these mails because core does
not pass the real name. Getting it would need core to pass `template_name: name`
(or the source) from `deliver_built/1`, which is a core change.

Tests: "an auth mail carrying its row in the private map is db with that uuid"
and "an auth mail that built from a file or default has no layer, whatever its
name is".

### 2. [NITPICK] `"file"`/`"module"` could be stored with a uuid — FIXED
**File:** `interceptor.ex` (`template_origin/2`)

A caller passing `template_source: "file"` together with a `template_uuid` got
both values stored. That contradicts the column's documented meaning ("the
database row the message was built from"). Only `"db"` now keeps the uuid.
Test: "a file or module layer named by the caller carries no uuid".

### 3. [BUG - MEDIUM] The new tests depend on the database having no `magic_link` row — FIXED
**File:** `test/phoenix_kit/modules/emails/log_template_source_test.exs`

Several tests use `"magic_link"` to mean "a core default with no row". On a
test database that holds a committed seeded `magic_link` row, 4 of them fail:
the lookup correctly answers `"db"`. The local shared test DB has nine system
rows committed on 2026-10-01, which leaked from some earlier run outside the
sandbox. These 4 tests also fail on the PR's own head commit. A fresh CI
database would pass, but the result should not depend on that. `setup` now runs
`Repo.delete_all(Template)` inside the sandbox, and the sandbox rolls it back.

### 4. [OBSERVATION] Extra query on every log write
`origin/3` runs one indexed query on the unique `name` per logged send that
carries no uuid, plus cached file probes. This is acceptable and documented.
Sends that have no template name skip it entirely.

### 5. [OBSERVATION] Details page loads in `mount/3`
`template_exists?/1` adds one `get_template/1` call to `load_email_data/1`,
which `mount/3` calls. That makes it run twice, once on the dead render and
once on the connected render. The pattern predates this PR (the log, events and
related emails already load there), so moving it to `handle_params/3` belongs
to a separate change.

## What Was Done Well
- The rule of naming a layer only when there is direct evidence, never a
  guess, is consistent throughout. `nil` is a real answer, and a caller's
  explicit `nil` skips the lookup.
- Logging never fails a send: bad uuids are dropped, and lookups rescue and
  catch exits.
- The migration is additive, nullable and has no FK, so a deleted template does
  not take its log lines with it. The badge link is shown only while the row
  exists.
- Thorough tests, including locale-specific file overrides and blank files.

## Verdict
Approved with fixes. The core logic is sound. The auth-mail gap (#1) meant the
feature missed its most common case; it is fixed using evidence core already
provides.
