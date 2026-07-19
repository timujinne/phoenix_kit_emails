# PR #8 Review — Per-module Gettext backend + widescreen + UI gettext wrapping

**Repo:** BeamLabEU/phoenix_kit_emails
**Head:** `timujinne:main` @ a9d5883 (3 commits ahead of merge-base)
**Base:** `BeamLabEU:main`
**Merge-base:** 96edda7 (Bump version to 0.1.3)
**Reviewer:** CLAUDE
**Date:** 2026-05-11

## Overview

The PR ships three independent changes on top of the 0.1.3 baseline:

1. **ad9260c** — adds `PhoenixKit.Modules.Emails.Gettext` backend and wires it into all 10 admin/settings `Tab.new!` calls via the `gettext_backend:` option introduced by [phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522). Ships en/ru/et catalogues for the 8 tab/group labels.
2. **b1663cb** — removes the `max-w-4xl mx-auto` outer wrapper in `settings.html.heex` so the page fills the container.
3. **a9d5883** — wraps 47 previously-raw strings in `settings.html.heex` (14) and `email_tracking.html.heex` (33) with `gettext()`; appends matching msgids to `default.pot`, `en/`, `ru/`, `et/` manually (no extract).

Adds `i18n_test.exs` smoke test (tab wiring + locale resolution) gated by an ExUnit tag controlled by `test_helper.exs` so the suite stays green on a phoenix_kit release that pre-dates #522.

## Verdict

**Initial verdict: REQUEST CHANGES.** Two HIGH-severity findings: the PR violates the global "no @version / no CHANGELOG edits" HARD RULE, and the branch is stale enough that the mix.lock will *regress* dependency versions on merge. Translation content itself is solid (msgid sets match across pot/en/ru/et, AWS technical terms preserved, no placeholder drift). Remaining items are scope-completeness and tooling robustness.

**Updated verdict (after `361d915`): COMMENT.** B-H1 (HARD RULE) resolved by the revert commit — `mix.exs` `@version` back to "0.1.3" and `CHANGELOG.md` net diff against the merge-base is empty. B-H2 (stale branch / mix.lock regression) tracked separately by the maintainer; per their direction, noted on the GitHub review but not gating this verdict. I-M1 / I-M2 noted as follow-ups, not gating.

---

## BUG — HIGH

### B-H1. `@version` bump and CHANGELOG entry violate the global HARD RULE

**Files:** `mix.exs:4`, `CHANGELOG.md:3-7`

```diff
- @version "0.1.3"
+ @version "0.1.4"
```

```diff
+ ## 0.1.4 - 2026-05-08
+
+ ### Added
+ - Per-module Gettext backend (...).
```

The global rule (CLAUDE.local.md, "Version + CHANGELOG ownership"): *Never bump `@version` in `mix.exs` and never write `CHANGELOG.md` entries. This rule applies uniformly to phoenix_kit core and every phoenix_kit_<x> child module.* The maintainer derives both from PR commit messages at release time.

This is exactly the situation that prompted the rule (Phase 2, May 8 2026 — every module PR bumped @version, maintainer overwrote each one on merge).

**Action:** revert both — leave `@version "0.1.3"` and drop the `## 0.1.4` block from `CHANGELOG.md`. (Note that upstream `main` has already moved past this — see B-H2 — so a rebase will resolve the CHANGELOG side, but the version bump must be intentionally dropped during rebase.)

### B-H2. Branch is stale; merge will regress dependency lockfile

**Files:** `mix.lock`

Upstream `main` advanced past the merge-base (96edda7) with three commits this PR does not contain:

- `4d6594c` — `Add per-module Gettext backend for sidebar tab labels` — **already merges this PR's commit ad9260c upstream.** The two commits land the same change with different OIDs; on rebase ad9260c becomes a no-op (or a merge conflict resolved by accepting either side).
- `ffe6958` — `Update deps and changelog for 0.1.4` — upstream already added the 0.1.4 entry.
- `e5a8dbc` — `lib upgrades` — bumped `mix.lock`.

As a result, the PR's `mix.lock` currently *regresses* the following on top of upstream `main`:

| package          | upstream main | PR head |
|------------------|---------------|---------|
| db_connection    | 2.10.1        | 2.10.0  |
| decimal          | 3.1.0         | 3.0.0   |
| ex_doc           | 0.40.2        | 0.40.1  |
| makeup_erlang    | 1.1.0         | 1.0.3   |
| mint             | 1.8.0         | 1.7.1   |
| phoenix_kit      | 1.7.106       | 1.7.95  |
| igniter          | 0.8.0         | 0.7.9   |
| ex_ast           | 0.11.0        | (removed) |

Merging as-is would silently downgrade these. Also note the `phoenix_kit 1.7.106 → 1.7.95` revert: 1.7.106 is the release that actually ships the `gettext_backend` Tab API (#522) that this PR depends on. Running tests against the regressed lockfile would put the suite back into the "skip i18n tests" branch of `test_helper.exs` — which silently passes without actually exercising the new wiring.

**Action:** rebase onto current `upstream/main`. Expect ad9260c to fold into / become equivalent to 4d6594c; keep b1663cb + a9d5883; resolve `CHANGELOG.md` by accepting upstream's `0.1.4` block and dropping the PR's duplicate entry; do not regress `mix.lock`.

---

## BUG — MEDIUM

### B-M1. "Graceful degradation on older phoenix_kit" claim is unverified for runtime, not just tests

**Files:** `lib/phoenix_kit/modules/emails/emails.ex:770-888`, `test/test_helper.exs`, commit ad9260c message

The commit message says:

> Requires the gettext_backend Tab API from BeamLabEU/phoenix_kit#522; on older releases tabs render raw English msgids (graceful degradation via test_helper.exs conditional skip).

But `test_helper.exs`'s conditional only governs **whether tests run**:

```elixir
if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
  ExUnit.start()
else
  ExUnit.start(exclude: [:requires_phoenix_kit_i18n_api])
end
```

That does nothing for the **runtime** path: `admin_tabs/0` still calls `Tab.new!(..., gettext_backend: PhoenixKit.Modules.Emails.Gettext, ...)` unconditionally. If a downstream consumer is on a phoenix_kit release that pre-dates #522 and `Tab.new!/1` raises on unknown keys (e.g. `KeyError`, struct-update error, or NimbleOptions-style validation), the entire admin sidebar will fail to register at boot.

I can't see the implementation here (lives in phoenix_kit core). The mix.exs constraint is `{:phoenix_kit, "~> 1.7"}`, which would resolve a wide range of versions, many of them pre-#522.

**Action:** either (a) tighten the constraint to `{:phoenix_kit, "~> 1.7.106"}` (or whichever release ships #522) and drop the "graceful degradation" language, or (b) confirm with a quick test against an older phoenix_kit that unknown `Tab.new!` opts are dropped silently, then leave a comment in `emails.ex` next to the first `gettext_backend:` line citing the floor version. The current state is ambiguous — readers (and the test suite) cannot tell which is true.

---

## IMPROVEMENT — MEDIUM

### I-M1. `settings.html.heex` i18n coverage is partial

**File:** `lib/phoenix_kit/modules/emails/web/settings.html.heex`

Walking the post-PR file, the following user-visible English strings remain raw — all in the IAM/SES setup walkthrough section that the PR otherwise updated:

```
Line 388: Visit <a ...>AWS IAM Console</a>
Line 394: Attach policies: <strong>SES</strong>, <strong>SQS</strong>, ...
Line 407: Enter Access Key ID (20 characters, e.g., <code>...</code>)
Line 412: Click <strong>"Verify Credentials"</strong> to test connectivity
Line 415-418: Click <strong>"Load regions"</strong> ... <em>Optional:</em> ...
Line 425: Click <strong>"Setup AWS Infrastructure"</strong> to create SNS/SQS resources
Line 432: Click <strong>"Save AWS Settings"</strong> ...
Line 451-456: Visit <a ...>AWS SES Console</a>
Line 475-479: <li><code>sqs:*</code> - Simple Queue Service</li> ... (the four bulleted permission lines)
Line 491-493: See <code>guides/aws_email_setup.md</code> for comprehensive documentation ...
```

These all mix inline `<strong>`/`<code>`/`<a>` markup with the user text, which is why the PR skipped them — `gettext("Click <strong>...")` would either translate the markup as text or require `raw/1`. Two clean options:

- Split the markup out — `gettext("Click %{verify_credentials_button} to test connectivity")` with `%{verify_credentials_button}` rendered via a separate component / `gettext_html`-style helper.
- Use `Phoenix.HTML.raw/1` around a translated string that already contains the markup (riskier — translators must reproduce the tags verbatim).

The commit message acknowledges the gap ("several remaining placeholders"); this is a flag rather than a hard blocker, but worth either landing in a follow-up or trimming the PR description's "47 strings" framing to reflect that the IAM/SES walkthrough is intentionally not fully covered yet.

### I-M2. `mix gettext.extract --merge` will obsolete the manually-maintained tab labels

**Files:** `priv/gettext/default.pot:1-10` (comment block), `lib/phoenix_kit/modules/emails/emails.ex`

The .pot comment block warns:

> Tab labels are not extracted automatically by `mix gettext.extract`
> (they live as plain strings in `Tab.new!(label: ...)`, not in a
> `dgettext` macro call), so this template is maintained manually.

This is a maintenance hazard. Anyone running the conventional `mix gettext.extract --merge` workflow (the suggested form in the autogenerated `.po` header that ships with this PR!) will produce a pot/po pair where the 8 tab-label msgids are dropped or marked obsolete (`#~`), while the 47 HEEX msgids re-extract cleanly. Translators or contributors unfamiliar with the manual-only branch will lose work.

Cheap fix: register the tab labels via a `gettext_noop/1` (or `dgettext_noop/1`) call inside `emails.ex`, e.g.

```elixir
defp register_tab_labels do
  # Solely so mix gettext.extract picks these up — the actual lookup
  # happens via Tab.localized_label/1 against `gettext_backend:`.
  _ = [
    gettext_noop("Emails"),
    gettext_noop("Dashboard"),
    gettext_noop("Email Details"),
    gettext_noop("Templates"),
    gettext_noop("New Template"),
    gettext_noop("Edit Template"),
    gettext_noop("Queue"),
    gettext_noop("Blocklist")
  ]
end
```

Then `mix gettext.extract --merge` works end-to-end and the comment block can be deleted. Worth doing now, while the catalogue is small.

---

## NITPICK

- **`en/default.po` style is mixed.** The 8 manual tab labels carry `msgstr "Emails"` (msgstr = msgid), the 47 extracted HEEX entries carry `msgstr ""`. Both resolve correctly at runtime (empty msgstr falls back to msgid for the default locale), but the inconsistency suggests two different authoring passes. Pick one.

- **`test_helper.exs` uses `Logger.info` for a build-time gating message.** ExUnit's own "Excluded N tests" report already surfaces this; the `Logger.info` is unlikely to be visible during a plain `mix test` run unless the consumer has logger backends wired explicitly. `IO.puts` would be more reliable, or just drop it.

- **`mix.exs` adds `:gettext` to `extra_applications`.** Likely redundant given the umbrella runs phoenix_kit which already starts `:gettext`, but harmless / defensive.

- **`PhoenixKit.Modules.Emails.Gettext` `@moduledoc` references `guides/per-module-i18n.md` in phoenix_kit core.** Worth confirming that guide exists in the version of phoenix_kit core this PR depends on — otherwise the reference is a dead link.

- **i18n_test.exs `setup` saves/restores locale but never sets it before `Gettext.put_locale(EmailsGettext, original)`.** `Gettext.get_locale(EmailsGettext)` will return either the configured default or the previously-set value; for `async: false` tests this is fine, but worth a `Gettext.put_locale(EmailsGettext, "en")` in setup so each test starts from a known locale.

---

## What looks good

- **Translations themselves.** RU and ET catalogues are natural and idiomatic. AWS technical names (IAM, SES, SQS, SNS, STS, ARN, Access Key ID, Secret Access Key) preserved verbatim — correct call, those are product names not common nouns. No placeholder drift since the wrapped strings have no `%{...}` interpolations.
- **msgid sets match across `default.pot`, `en/`, `ru/`, `et/` (56 entries each).** Verified with `grep -c '^msgid '` and a sorted-diff between pot and ru — identical.
- **`emails.ex` wiring is consistent** — all 10 `Tab.new!` calls take the same `gettext_backend: PhoenixKit.Modules.Emails.Gettext`. No inline `gettext_domain:` overrides, which is appropriate (all labels stay in `default`).
- **The widescreen change is minimal and correct** — drops a single `max-w-4xl mx-auto` wrapper; numeric input `max-w-xs` caps were intentionally preserved (good — those short fields would look weird stretched).
- **Test scaffolding is honest** — the conditional skip with a clear tag name (`:requires_phoenix_kit_i18n_api`) and explanatory `@moduletag` comment is better than silently skipping or hardcoding a version check.

---

## Required actions before merge

1. Revert `@version` bump in `mix.exs` and drop the `## 0.1.4` block from `CHANGELOG.md` (B-H1).
2. Rebase onto current `upstream/main` and verify the resulting `mix.lock` does not regress any package (B-H2). Confirm that ad9260c folds cleanly into the already-merged 4d6594c.
3. Either tighten the `phoenix_kit` constraint to a version that includes #522 or verify (and document) that older `Tab.new!` ignores unknown opts (B-M1).

## Optional follow-up

4. Convert tab-label msgids to `gettext_noop/1` in `emails.ex` so `mix gettext.extract --merge` is safe (I-M2).
5. Finish the IAM/SES walkthrough i18n coverage in a follow-up PR (I-M1), or trim the PR description framing.

---

## Findings summary

| Severity            | Count |
|---------------------|-------|
| BUG - CRITICAL      | 0     |
| BUG - HIGH          | 2     |
| BUG - MEDIUM        | 1     |
| IMPROVEMENT - HIGH  | 0     |
| IMPROVEMENT - MEDIUM| 2     |
| NITPICK             | 5     |
