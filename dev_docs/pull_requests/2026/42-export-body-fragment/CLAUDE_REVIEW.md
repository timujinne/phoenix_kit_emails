# Code Review: PR #42 — Export template bodies as fragments for core's email layout

**Reviewed:** 2026-10-01
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_emails/pull/42
**Author:** timujinne
**Head SHA:** 1f26355
**Status:** Merged

## Summary

`mix phoenix_kit_emails.templates.export` used to write each edited system
template's `html_body` — a whole HTML document — to `html.html`. Core wraps an
email built from a file in `PhoenixKit.Email.Layout` but never wraps a document,
so an exported document kept its old chrome for good. The PR adds `--html
auto|body|document` and a new `TemplateExport.Body` that cuts the body fragment
out of the stored document:

- a dependency-free tag tokenizer with balanced-element search (no HTML parser);
- the cut is made on the `.header` / `.footer` boundary; a header holding a
  heading or placeholder and a footer holding a placeholder are kept as content;
- the `<style>` block's rules (`tag`, `.class`, `tag.class`, descendant chains)
  are inlined into `style` attributes, existing inline styles winning;
- new notices (`:body_fallback`, `:chrome_dropped`, `:injected_styles`,
  `:style_placeholder`, `:document_on_disk`) reported by the task, reconciled
  for skipped files.

## Verification done

- Ran `Body.extract/1` over every seed in `Templates.default_system_templates/0`
  (9 templates, auth + billing + test_email). All cut cleanly with no notes; the
  auth seeds keep their `<h1>` title, button, notice box and the `{{..._url}}`
  fallback footer, with `.button` / `.warning` / `.footer` inlined and the
  `:hover` rule skipped.
- Probed uppercase tags, no `<body>`, header-only/missing-footer shapes (clean
  `:chrome_dropped` or `:body_fallback`), unclosed `<p>`/`<li>`, a `>` inside a
  quoted attribute, `<style>` with a placeholder between rules.
- `export_html_file/4` cuts first and rewrites `{{{raw}}}` afterwards, so the
  raw-HTML notices see the written content; `existing_document_notice/3` is
  only consulted for `:skipped` outcomes, and `reconcile_skipped_notice/2`
  passes it through unchanged. The `for ..., notice = expr` filter in the task
  works as intended (a `nil` match is falsy).
- `mix test`: 640 tests, 0 failures before my changes.

## Issues Found

### 1. [BUG - MEDIUM] An unquoted attribute value ending in `/` is read as a self-closing tag — FIXED
**File:** `lib/phoenix_kit/modules/emails/template_export/body.ex` (tokenizer, `split_tail/1`)
The tokenizer decided a tag was self-closing with
`String.ends_with?(trimmed_attrs, "/")`. For `<a href=https://x.com/>go</a>`
the `/` belongs to the unquoted value, per the HTML spec. The tag became a void
element, so its `</a>` was a stray close; `balanced?/3` then saw a close it
never opened, the header/footer were judged "not siblings", and the export fell
back to the whole `<body>` — header and footer included, which the layout then
doubles. Separately, `rebuild/3` stripped that same `/` off the URL when it
added a `style`, writing `href=https://x.com` and a bogus ` />`.
Fixed with `self_closing?/1`: the trailing `/` only closes the tag when it is not
consumed by the last attribute's value (`attr_spans/1`). `<br/>`,
`<img src="a"/>`, `<hr class="r" />` and `<input disabled/>` still self-close.
Regression test added; it fails without the fix.
**Confidence:** 90/100

### 2. [NITPICK] `<pre>`/`<textarea>` disables de-indenting for the whole block — FIXED (docs)
**File:** `lib/phoenix_kit/modules/emails/template_export/body.ex` (`tidy/1`, moduledoc)
The moduledoc said the indentation and blank-line tidying is skipped "inside
`<pre>` or `<textarea>`". `tidy/1` actually tests the whole piece for a `<pre>`
and, if one is there, only trims the piece's edges — so every other line of the
middle section keeps the seed's nesting indentation. Output is still correct
(whitespace outside `<pre>` is insignificant in HTML); only the claim was wrong.
Not changed in code: handling it per-region needs the tidy step to know element
boundaries, which is more machinery than cosmetic indentation is worth. The
moduledoc now says what happens.
**Confidence:** 90/100

### 3. [OBSERVATION] Header-background-dependent styling is lost on the billing seeds
**File:** `lib/phoenix_kit/modules/emails/template_export/body.ex` (`render_header/3`)
The billing seeds' header carries a dark gradient and white text; the kept
header reduces to `text-align`/margins, so `.invoice-number`, `.receipt-number`
and similar classes written for that background lose their colour and size
rules. The inline-styled badges survive (`rgba(255,255,255,0.2)` background, now
on white). This is the documented trade-off ("not its background, colour or the
descendant rules written for that background"); it degrades to plain text, not
to a broken email, and the layout is where such styling now belongs. Left alone.

### 4. [OBSERVATION] `{{{line_items_html}}}` rows render unstyled
Already documented in the README, moduledoc and a task warning (`:injected_styles`);
the fix belongs in `phoenix_kit_billing`, which owns those rows.

## What Was Done Well

- The tokenizer and the cut are written for hostile input: unterminated
  tags/comments/`<style>` collapse to text, ancestor tracking is one forward
  pass, depth and rule counts are capped, and the limits that remain are stated.
- Nothing outside the header/footer is dropped silently — every dropped piece of
  text is reported so it can be moved to a `_layout`.
- `--html auto` is conservative: it only writes a fragment where the loaded core
  has `PhoenixKit.Email.Layout`, and `document?/1` defers to core's own function
  so export and send agree.
- 1,300 lines of tests, including seed-shaped documents and a check that the
  local `document?/1` agrees with core's.

## Verdict

Approved with fixes — the design is sound and the seeds export correctly. One
real defect (unquoted attribute ending in `/`) is fixed with a regression test;
the rest are documentation and accepted trade-offs.
