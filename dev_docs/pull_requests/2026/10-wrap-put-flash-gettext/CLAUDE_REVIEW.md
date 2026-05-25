# Code Review: PR #10 — Wrap Emails LiveView put_flash messages in gettext

**Reviewed:** 2026-05-25
**Reviewer:** Claude (claude-opus-4-7)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/10
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** b076ec93a6c365d7de32e84935cfa224f9be064d
**Status:** Merged (reviewed post-merge)

## Summary

Follow-up to #9. #9 routed the LiveViews through the local Gettext backend but
only wrapped HEEX template strings; the `.ex` files still emitted ~100 hardcoded
English `put_flash` messages, so ru/et users got localised chrome plus English
flashes on every toggle/error/confirmation.

- Wraps 100+ `put_flash(socket, _, "literal")` calls across all 9 LiveView
  modules in `gettext(…)`.
- Converts interpolations from `#{var}` → `%{var}` with keyword bindings
  (e.g. `gettext("Email retention period updated to %{days} days", days: …)`).
- Keeps emoji prefixes (✅ ❌ ⚠️ ℹ️) **outside** `gettext` via string
  concatenation: `"❌ " <> gettext("Email log not found")` — so they survive in
  every locale and don't pollute msgids.
- Corrects 5 previously-fuzzy entries; `mix gettext.extract --merge` adds 86
  msgids, en/ru/et filled.
- Explicitly leaves multi-line heredoc AWS reports in `settings.ex`, Chart.js
  labels in `metrics.ex`, and the delete-confirm modal in `templates.ex` out of
  scope.

## Issues Found

### 1. [OBSERVATION] Placeholders are consistent across all locales
Audited every `%{…}` placeholder in the new ru/et/en msgstrs against its msgid.
**All match** — no `Gettext.MissingBindingError` risk at runtime (the classic
failure mode where a translator renames `%{count}` and the flash crashes the
event). The `%{var}` conversion was done carefully.
**Confidence:** 100/100

### 2. [OBSERVATION] Interpolating opaque values into translatable strings
**File:** several (`emails.ex`, `queue.ex`, `blocklist.ex`, `settings.ex`)
Patterns like `gettext("Failed to retry email: %{reason}", reason: reason)` and
`gettext("Failed to send test email: %{reason}", reason: inspect(reason))`
interpolate an untranslated, often `inspect/1`-formatted error tail into an
otherwise localised sentence. This is the pragmatic choice and is fine — just
note the localisation stops at the colon; the reason itself stays English/raw.
No change needed.
**Confidence:** 95/100

### 3. [OBSERVATION] Emoji concatenation pattern
`"✅ " <> gettext("…")` is the right call (emoji out of the msgid). Minor
consistency note: a few flashes carry emoji and many don't, so the localised UX
is slightly uneven across actions — cosmetic, not worth churning.
**Confidence:** 85/100

## What Was Done Well

- **Mechanically thorough and low-risk.** Pure string-wrapping; no control-flow,
  data-loading, or `mount/3` changes. No Phoenix anti-patterns.
- **Placeholder discipline.** Every interpolation became a named `%{var}` binding
  with matching translations in all three locales — the single most important
  correctness property for flash i18n, and it holds.
- **Correctly depends on #9.** Flash msgids can only resolve once the per-module
  backend is wired; the dependency is called out and ordering respected.
- **Honest scoping.** Heredoc reports / chart labels / modal text deferred with
  rationale rather than half-wrapped.

## Verification (local, post-merge)

- `mix compile` — clean.
- `mix gettext.extract --check-up-to-date` — exit 0 (POT in sync; no unextracted
  flash strings).
- `mix test` — 14 tests, 1 failure: the pre-existing
  `PhoenixKit.Email.Provider` behaviour assertion, unrelated to this PR.
- Placeholder audit across ru/et/en — consistent, no fuzzy entries remaining.

## Verdict

**Approved** — already merged. No correctness issues found; placeholder handling
across locales is solid.

## Cross-cutting note (applies to #9 + #10, not a blocker)

The working tree has an **uncommitted `mix.lock`** dependency refresh (bandit
1.11.0→1.11.1, ecto/ecto_sql 3.13→3.14, fresco 0.1→0.6, new `etcher` dep, erlex,
ex_ast, ex_doc) that is **not part of either PR**. Decide whether to commit it
deliberately (it changes resolved deps for consumers) before cutting the next
0.1.5 Hex release, rather than letting it ride along silently.
