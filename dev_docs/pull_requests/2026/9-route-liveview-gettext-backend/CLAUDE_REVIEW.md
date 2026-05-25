# Code Review: PR #9 — Route Emails LiveView gettext through the module backend

**Reviewed:** 2026-05-25
**Reviewer:** Claude (claude-opus-4-7)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/9
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a9af5f56a45a2fe7ae84ca2460babf910f2aa0ac
**Status:** Merged (reviewed post-merge)

## Summary

Fixes the root cause behind RU/ET users seeing English fallbacks: the Emails
LiveViews inherited `use Gettext, backend: PhoenixKitWeb.Gettext` via
`use PhoenixKitWeb, :live_view`, so every `gettext("…")` in the HEEX templates
resolved against the *parent app's* catalogues — which never carried these
msgids. This package's own `priv/gettext/{ru,et}` translations were never
consulted at render time.

- Adds `use Gettext, backend: PhoenixKit.Modules.Emails.Gettext` to all 9
  LiveView modules (blocklist, details, email_tracking, emails, metrics,
  queue, settings, templates, template_editor), re-importing the `gettext/N`
  macros bound to the local backend. Matches the per-module-i18n.md guide in
  phoenix_kit core and the sidebar pilot from PR #7.
- Wraps the remaining raw template strings, notably the full IAM/SES setup
  walkthrough in `settings.html.heex` (mixed `<strong>`/`<a>`/`<code>` markup),
  plus stragglers in emails/templates/blocklist/template_editor.
- `mix gettext.extract --merge`: `default.pot` 56 → 447 msgids; en/ru/et filled.
- `mix.exs`: `{:phoenix_kit, "~> 1.7"}` → `"~> 1.7.106"`.

## Issues Found

### 1. [BUG] Catalogue mis-fills — wrong msgstr values across all three locales — FIXED
**Files:** `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po`
What started as a single `%{uuid}` drop turned out to be a systematic mis-fill
from the bulk catalogue regeneration in commit `e157cbc`: runs of adjacent
entries received a neighbour's `msgstr`.

**`en` — 12 entries had `msgstr` ≠ `msgid`** (en must always be `msgstr == msgid`):
`Archive Template`/`Clone Template`/`New Template Name` → "New Template";
`Email` → "Emails"; `Queued` → "Queue"; `Template`/`Template Name` →
"Templates"; `Email Templates`/`Email actions`/`Emails Disabled`/`Emails
Settings`/`Email Details %{uuid}` → "Email Details". Result: English users saw
the wrong label (e.g. the Archive tooltip read "New Template") and lost the
`%{uuid}`. All 12 reset to `msgstr = msgid`.

**`ru` + `et` — 7 genuine cross-locale mistranslations** (the *same* copy-paste
bug propagated, so a native speaker wouldn't have caught them by reading the
target alone):
| msgid | was (ru / et) | fixed to (ru / et) |
|---|---|---|
| Archive Template | Новый шаблон / Uus mall | Архивировать шаблон / Arhiveeri mall |
| Clone Template | Новый шаблон / Uus mall | Клонировать шаблон / Klooni mall |
| New Template Name | Новый шаблон / Uus mall | Имя нового шаблона / Uue malli nimi |
| Queued | Очередь / Järjekord | В очереди / Järjekorras |
| Email (System Status label) | Письма / E-kirjad | Email / E-post |
| Setup AWS Infrastructure (button) | 3. Настроить инфраструктуру / 3. Seadista taristu | Настроить инфраструктуру AWS / Seadista AWS taristu |
| AWS SES Events Options (heading) | Отслеживание событий AWS SES / AWS SES sündmuste jälgimine | Параметры событий AWS SES / AWS SES sündmuste valikud |

`Setup AWS Infrastructure` is the clearest: it's a **button** that was rendering
the heading's "3." step prefix. `Email` is the System-Status row meaning the
email *service* (not a single message), so ru keeps "Email" / et "E-post".

All fixed in this review pass. Verified post-fix: en has zero `msgstr ≠ msgid`,
no placeholder mismatches in any locale, and `mix gettext.extract
--check-up-to-date` still exits 0 (only `msgstr` values changed, no msgids).
ru/et fixes are high-confidence for Russian; **the Estonian strings are standard
UI terms but a native speaker should sanity-check `E-post` and `Järjekorras`.**
**Confidence:** 100/100 (bug existence) · 90/100 (et wording)

### 2. [OBSERVATION] `Phoenix.HTML.raw/1` on translated HTML strings
**File:** `settings.html.heex`, `template_editor.html.heex`
8 msgids contain inline markup (`<strong>`, `<code>`) and are correctly wrapped
in `Phoenix.HTML.raw(...)` — verified each one; none were missed, so no literal
`<strong>` leaks to the page. This is safe **only because the `.po` files are
repo-controlled**. If translation sourcing ever opens up (external PRs,
translation service), these become a stored-XSS surface. Worth a one-line
comment near one of the `raw` sites documenting the trust assumption.
**Confidence:** 90/100

### 3. [OBSERVATION] `en` msgstr = msgid convention
The PR fills `en` with `msgstr == msgid` for every entry, citing "without it the
`en` locale returns empty string." Standard Elixir Gettext actually falls back to
the (interpolated) msgid on an empty msgstr, so this isn't strictly required —
but populating `en` explicitly is harmless, conventional, and makes the catalogue
self-documenting. No action needed.
**Confidence:** 80/100

## What Was Done Well

- **Correct fix at the right layer.** Re-importing the macros per-module is
  exactly how you override an inherited Gettext backend; no hacks.
- **Catalogues are in sync with source** — `mix gettext.extract --check-up-to-date`
  exits clean, so there are no unextracted/stale msgids.
- **HTML strings handled properly:** placeholders moved to `%{var}` keyword
  bindings (translator-friendly word order), nested `gettext` for button labels,
  and `Phoenix.HTML.raw` only where markup is intended.
- **No Phoenix anti-patterns introduced.** Changes are display-only — no queries
  added to `mount/3`, no PubSub, no data-loading shifts. The Iron Law is intact.

## Verification (local, post-merge)

- `mix compile` — clean.
- `mix gettext.extract --check-up-to-date` — exit 0 (POT in sync).
- `mix test` — 14 tests, 1 failure: the pre-existing
  `PhoenixKit.Email.Provider` behaviour assertion (`behaviours: []`), unrelated
  to this PR.
- Placeholder audit across ru/et/en `.po`: only the en "Email Details %{uuid}"
  mismatch above; no remaining fuzzy entries.

## Verdict

**Approved** — already merged. The backend-routing fix itself is correct; the
only real problem was the bulk catalogue regeneration mis-filling msgstr values
(#1), now fixed in a follow-up commit on `main`. Everything else is clean and
forward-compatible.
