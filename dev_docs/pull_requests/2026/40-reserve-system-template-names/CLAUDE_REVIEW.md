# Code Review: PR #40 — Reserve system template names and allow archiving them from the UI

**Reviewed:** 2026-09-24
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/40
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** ee134d607094933342884a51e89cd4838b55d8f8
**Status:** Merged

## Summary

- `Template.reserved_names/0` lists 13 names that core's `PhoenixKit.Email.Content.resolve/5` looks up by exact string. A changeset validation stops a non-system row from claiming one of them. The check runs only when `:name` or `:is_system` changes, so a row that already holds a reserved name can still be edited or archived.
- `:is_system` is no longer cast from `attrs`. The new third argument, `Template.changeset/3`, can set it, and the only caller that does is `seed_system_templates/0`, through `create_system_template/1`. This closes the gap where a crafted LiveView event could create or promote a system row.
- System templates can now be archived and activated from the Templates list, after a confirmation modal that explains the fallback. Delete is still blocked for system rows.
- The editor disables the Status select for system rows and removes `status` from the params on the server, so status only changes through the confirmation flow.
- Archive, activate and clone failures now show the first changeset error in the flash instead of a generic message.

I checked the reserved-names list against its real sources. Core's `user_notifier.ex` uses `register`, `reset_password`, `update_email`, `organization_invitation`, `magic_link_registration`, `new_login_alert` and `failed_login_alert`. `mailer.ex` uses `magic_link`. `phoenix_kit_billing` uses four `billing_*` names through `send_from_template/4`, and this package uses `test_email`. The list is complete and has no extra entries.

## Issues Found

### 1. [BUG - HIGH] Cloning from the UI always failed — FIXED
**File:** `lib/phoenix_kit/modules/emails/templates.ex`, `clone_template/3`

`clone_template/3` wraps the caller's `display_name` string into `%{"en" => ...}` inside `base_attrs`. It then ran `Map.merge(base_attrs, attrs)`, which put the raw string back over the map. The clone modal always sends `display_name`, because `validate_clone_form/1` requires it. So every clone from the UI failed the `:map` cast with `display_name: is invalid` / `must have at least one language`.

This bug predates the PR and goes back to `bf7951a`. The PR's own test brought it to light: its "reserved-name reason" clone test logged the `display_name` cast error next to the reserved-name error. That test passed only because it expected the clone to fail anyway.

**Fix:** `attrs` no longer includes `:display_name` when it is merged. Two regression tests cover this: `Templates.clone_template/3` with a string display name, and the `clone_template` LiveView event succeeding end to end.
**Confidence:** 98/100

### 2. [IMPROVEMENT - MEDIUM] Clone modal did not flag a reserved name until submit — FIXED
**File:** `lib/phoenix_kit/modules/emails/web/templates.ex`, `validate_clone_form/1`

The inline validation checked format and whether the name already exists. It did not check reserved names, so a reserved name with no existing row passed `validate_clone` and failed only on submit, with a flash message. It now checks `Template.reserved_names/0` and shows the error inline on keystroke. The submit-time flash path is still there as a backstop.
**Confidence:** 90/100

### 3. [NITPICK] `changeset_error_reason/1` interpolated every opt with `to_string/1` — FIXED
**File:** `lib/phoenix_kit/modules/emails/web/templates.ex`

The reducer called `to_string(value)` on every opt, even when the message has no matching placeholder. Error opts can hold values that `String.Chars` can't convert, such as a cast error's `type: {:array, _}` or `{:map, _}`. That would crash the handler while it is building an error flash. Nothing in the current schema triggers it, because every cast type is a plain atom, but the code was one field change away from it. It now works like the Phoenix generator's `translate_error`: it replaces only the `%{key}` placeholders that are present and moves the lookup into `interpolate_error_opt/3`, which also keeps credo's nesting check satisfied.
**Confidence:** 80/100

### 4. [OBSERVATION] The four unseeded reserved names cannot get a database override
`organization_invitation`, `magic_link_registration`, `new_login_alert` and `failed_login_alert` are reserved but have no seed. No row can exist for them, so layer 1 of `Content.resolve/5` never applies to them. Before this PR an admin could create one of these rows on purpose to customize the email. Now they can't. This fits core's direction: the `Content` moduledoc calls the DB layer transitional and file overrides (`priv/phoenix_kit_templates/<name>/`) the way forward. It still narrows behavior, so it should be mentioned in the CHANGELOG. Not changed.

### 5. [OBSERVATION] Seeding does not repair an existing hijack row
`seed_system_templates/0` returns an existing row by name unchanged. A non-system row that took a reserved name before this validation shipped stays non-system and keeps winning at layer 1. Promoting it automatically would keep content someone else wrote, so the right fix is for an operator to archive or rename it. The PR allows that, because the validation is gated on changed fields. Not changed.

### 6. [OBSERVATION] `test/core_pin_conformance_test.exs` fails, unrelated to this PR
`mix.exs` pins `{:phoenix_kit, ">= 2.21.3 and < 3.0.0"}` on purpose (`fb5a999`, the rename of the Integrations page). The conformance test still requires the pin to admit core 2.0.0. It fails the same way on `main` before this review's changes. The test or the pin needs a decision from the maintainer, so neither was changed here.

## What Was Done Well

- The reserved list comes from the real call sites in core and billing, not from this package's own seed list. That is how the four unseeded names were found.
- The validation runs only when `:name` or `:is_system` changes, so existing hijack rows can still be fixed. The reason is written in a comment.
- The `is_system` escalation is closed in the changeset, not only in the UI, and tests use the same trusted path to build fixtures.
- The server removes the locked `status` field too, not just the disabled `<select>`.
- The buttons have stable ids, and the tests target them by id rather than by matching a substring.

## Verdict

**Approved with fixes.** The PR does what it says. The serious problem found, clone failing every time, predates the PR, and the PR's own test surfaced it. It is fixed and covered by tests. `mix precommit` passes, and `test/phoenix_kit/modules/emails` passes (486 tests, 0 failures). Issue 6 is the only failure in the full suite and predates this PR.
