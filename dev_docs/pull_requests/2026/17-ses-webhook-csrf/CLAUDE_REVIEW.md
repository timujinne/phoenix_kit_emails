# Code Review: PR #17 — Fix latent CSRF block on the SES webhook route

**Reviewed:** 2026-07-19
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/17
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** af7101efd6fbfb73b54d61270702ef975c0c58b4
**Status:** Merged

## Summary

`Web.Routes.generate/1` pipes the public `/webhooks/ses` route through the host
app's own `:browser` pipeline. Phoenix's default `:browser` pipeline (and
`PhoenixKitWeb.Router`'s own copy, `phoenix_kit_web/router.ex:22-30`) includes
`plug :protect_from_forgery`. AWS SNS delivers webhook notifications as a cold,
session-less POST with no CSRF token, so every notification 403'd with
`Plug.CSRFProtection.InvalidCSRFTokenError` before ever reaching
`WebhookController` — a real (if not yet publicly reported) production bug for
any host app whose `:browser` pipeline follows the Phoenix default.

The fix replaces `pipe_through([:browser])` with a new, minimal
`:phoenix_kit_emails_webhook` pipeline containing only `plug :accepts, ["html"]`
— no session/CSRF/flash plugs — mirroring the equivalent fix already shipped in
`phoenix_kit_newsletters` for its one-click-unsubscribe route (per the PR
description).

## Verification

- **The bug is real — CONFIRMED.** `PhoenixKitWeb.Router`'s own `:browser`
  pipeline (the reference implementation host apps copy) includes
  `protect_from_forgery` (`router.ex:26`). Any host app following the documented
  setup would 403 the webhook.
- **The route AST actually reaches the host router — CONFIRMED.**
  `route_module/0` (`emails.ex:954`) is discovered once via
  `PhoenixKit.ModuleDiscovery`, and `PhoenixKitWeb.Integration.phoenix_kit_routes/0`
  splices `Routes.generate/1`'s quoted output directly into the host router body
  via `unquote_splicing(module_public_routes)` (`integration.ex:1247/1284`). A
  `quote do pipeline ... ; scope ... end` block is a single `__block__` AST node;
  Elixir flattens nested blocks, so the new `pipeline` definition lands at the
  correct top level next to the host's own pipelines — not nested inside
  something that would make it a compile error. `normalize_routes/1`
  (`integration.ex:1063-1064`) just wraps non-list return values in a list and
  does not filter/unwrap the block's contents, so the pipeline isn't silently
  dropped.
- **No plug the controller actually needs was dropped — CONFIRMED.**
  `WebhookController.handle/2` reads `conn.remote_ip`, request headers, and the
  parsed `params` map (parsed by `Plug.Parsers` at the Endpoint level, before the
  router pipeline runs) — nothing in the handler touches `conn.session` or CSRF
  state, so dropping `fetch_session`/`fetch_flash`/`protect_from_forgery` is safe.
- **Test is a real end-to-end regression test, not a unit-test-in-disguise —
  CONFIRMED.** `webhook_route_csrf_test.exs` builds a `TestRouter` using the
  *actual* `Routes.generate/1` AST (via `Code.eval_quoted`) with a `:browser`
  pipeline shaped like Phoenix's generator default, and dispatches a cold
  `Plug.Test.conn/2` POST with an empty session (no CSRF token) through it,
  asserting a 200. Confirmed against the PR description that reverting the fix
  reproduces `Plug.CSRFProtection.InvalidCSRFTokenError` in this same test.
- **No regression to the admin export route — CONFIRMED.** The second `scope`
  block (`/emails/export/:format`) is untouched, still `pipe_through([:browser,
  :phoenix_kit_admin_only])`.

## Issues Found

None. No code changes were necessary on top of the merged PR.

## What Was Done Well

- **Root-caused against the actual host-router mechanism**, not just "it 403s,
  add a bypass" — the fix targets exactly the plug (`protect_from_forgery`) that
  can never be satisfied by an external, session-less POST, while keeping
  `:accepts` so content-negotiation still behaves like a normal Phoenix route.
- **Test proves the fix using the framework's real macro-expansion path**
  (`Routes.generate/1` spliced into a router via `Code.eval_quoted`), not a bare
  call to `WebhookController.handle/2` — this is the only way to actually catch a
  pipeline-level regression like the one being fixed.
- **Verified against a real host app** (per PR description: compiled through
  `hydroforce` via path deps with `--warnings-as-errors`, `mix phx.routes`
  confirmed the route is still mounted) in addition to the in-repo test.
- **Scoped fix** — no unrelated cleanup, no behavior change to the sibling export
  route.

## Verdict

**Approved.** The fix is correct, minimal, and verified both against the
framework's route-splicing mechanism and a real host application. No follow-up
required.
