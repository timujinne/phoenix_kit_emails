defmodule PhoenixKit.Modules.Emails.TemplateExport.BodyTest do
  @moduledoc """
  Cutting a stored full-document `html_body` down to the body fragment an
  `html.html` override holds — on documents shaped like the seeds, and on the
  shapes hosts turn them into.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Modules.Emails.TemplateExport.Body

  @css """
  body { font-family: sans-serif; color: #333; }
  .header { text-align: center; margin-bottom: 30px; background: linear-gradient(#000, #111); color: white; }
  .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; }
  .button:hover { background-color: #2563eb; }
  .footer { margin-top: 30px; border-top: 1px solid #e5e7eb; font-size: 14px; }
  .warning { background-color: #fef3c7; padding: 16px; }
  .content { padding: 30px; }
  """

  # The shape of the four auth seeds: the body sits directly between the
  # header and the footer, in no wrapper of its own.
  defp auth_doc(opts \\ []) do
    title = Keyword.get(opts, :title, "Welcome! Please confirm your account")
    greeting = Keyword.get(opts, :greeting, "Hi {{user_email}},")
    css = Keyword.get(opts, :css, @css)
    header = Keyword.get(opts, :header, ~s(<h1>#{title}</h1>))

    footer =
      Keyword.get(
        opts,
        :footer,
        ~s(<p>Or paste this link:</p>\n      <p><a href="{{confirmation_url}}">{{confirmation_url}}</a></p>)
      )

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Confirm</title>
      <style>
    #{css}
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          #{header}
        </div>

        <p>#{greeting}</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{confirmation_url}}" class="button">Confirm My Account</a>
        </p>

        <div class="warning">
          <strong>Note:</strong> secure link.
        </div>

        <div class="footer">
          #{footer}
        </div>
      </div>
    </body>
    </html>
    """
  end

  # The shape of five seeds: the body is wrapped in `.content`.
  defp content_doc do
    """
    <!DOCTYPE html>
    <html>
    <head><style>#{@css}</style></head>
    <body>
      <div class="container">
        <div class="header"><h1>Invoice</h1></div>
        <div class="content">
          <p>Dear {{user_name}}</p>
          <table><tr><td>{{{line_items_html}}}</td></tr></table>
        </div>
        <div class="footer"><p>{{company_name}}</p></div>
      </div>
    </body>
    </html>
    """
  end

  defp placeholders(html) do
    ~r/\{\{\{?\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}?\}\}/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  describe "document?/1" do
    test "recognises a doctype or an <html> tag, in any case, after a prolog" do
      assert Body.document?("<!DOCTYPE html><html></html>")
      assert Body.document?("<!doctype html>")
      assert Body.document?("<HTML lang=\"en\"><body></body></HTML>")
      assert Body.document?("﻿  \n<!-- c --><?xml version=\"1.0\"?>\n<html>")
    end

    test "a fragment is not a document" do
      refute Body.document?("<p>Hi</p>")
      refute Body.document?("<htmlish>")
      refute Body.document?("")
      refute Body.document?("Hello <html> later")
    end
  end

  describe "extract/1 — fragments and documents" do
    test "a fragment comes back unchanged, without notes" do
      assert Body.extract("<p>Hi {{name}}</p>\n") == {"<p>Hi {{name}}</p>\n", []}
    end

    test "cuts the document down to the body: no head, style, body or container" do
      {fragment, notes} = Body.extract(auth_doc())

      assert notes == []

      for gone <- [
            "<html",
            "<head",
            "<style",
            "<body",
            "<!DOCTYPE",
            "<title",
            ~s(class="container")
          ] do
        refute fragment =~ gone, "#{gone} should be gone"
      end

      assert fragment =~ "<p>Hi {{user_email}},</p>"
      assert fragment =~ ~s(href="{{confirmation_url}}")
      # the container's closing tag went with its opening one
      assert length(String.split(fragment, "<div")) == length(String.split(fragment, "</div>"))
    end

    test "the body is whatever sits between the header and the footer, with or without .content" do
      {auth, _} = Body.extract(auth_doc())
      {with_content, _} = Body.extract(content_doc())

      assert auth =~ "Confirm My Account"
      assert with_content =~ "Dear {{user_name}}"
      # `.content` is unwrapped — the layout owns padding — so its rule is not applied.
      refute with_content =~ ~s(class="content")
      refute with_content =~ "padding: 30px"
    end

    test "a .content that does not wrap the whole region is left alone" do
      doc =
        String.replace(
          content_doc(),
          ~s(<table>),
          ~s(</div><p>after</p><div class="content"><table>)
        )

      {fragment, _} = Body.extract(doc)
      assert fragment =~ "after"
    end

    test "every placeholder of the original body survives" do
      for doc <- [auth_doc(), content_doc()] do
        {fragment, _} = Body.extract(doc)
        [_, body] = Regex.run(~r/<body>(.*)<\/body>/s, doc)
        assert MapSet.subset?(placeholders(body), placeholders(fragment))
      end
    end

    test "raw {{{triple}}} placeholders pass through untouched" do
      {fragment, _} = Body.extract(content_doc())
      assert fragment =~ "{{{line_items_html}}}"
    end

    test "a host's edits in several locales come through, each file on its own" do
      de =
        auth_doc(
          title: "Willkommen! Bitte bestätigen",
          greeting: "Hallo {{user_email}}, schön dass Sie da sind"
        )

      ru = auth_doc(title: "Добро пожаловать", greeting: "Здравствуйте, {{user_email}} 👋")

      {de_fragment, []} = Body.extract(de)
      {ru_fragment, []} = Body.extract(ru)

      assert de_fragment =~ "Willkommen! Bitte bestätigen"
      assert de_fragment =~ "Hallo {{user_email}}, schön dass Sie da sind"
      assert ru_fragment =~ "Добро пожаловать"
      assert ru_fragment =~ "Здравствуйте, {{user_email}} 👋"
      refute de_fragment =~ "Здравствуйте"
    end

    test "the result is a fragment: extracting it again changes nothing" do
      {once, _} = Body.extract(auth_doc())
      assert Body.extract(once) == {once, []}
    end

    test "indentation of the seed's nesting is removed and edges are trimmed" do
      {fragment, _} = Body.extract(auth_doc())

      assert String.starts_with?(fragment, "<div")
      assert String.ends_with?(fragment, "</div>\n")
      refute fragment =~ "\n\n\n"
      refute fragment =~ ~r/^ {6,}</m
    end
  end

  describe "extract/1 — header and footer" do
    test "a header with a heading keeps the title, without its own background or colour" do
      {fragment, []} = Body.extract(auth_doc())

      assert fragment =~ "<h1>Welcome! Please confirm your account</h1>"
      assert fragment =~ "text-align: center"
      refute fragment =~ "linear-gradient"
      [header_block | _] = String.split(fragment, "</div>")
      refute header_block =~ "white"
      refute fragment =~ ~s(class="header")
    end

    test "a header with no heading is chrome: dropped, and its text is reported" do
      {fragment, notes} =
        Body.extract(auth_doc(header: ~s(<img src="x.png" alt="Acme Ltd">Acme Ltd)))

      refute fragment =~ "Acme Ltd"
      assert {:chrome_dropped, ["header: Acme Ltd"]} in notes
    end

    test "a header with nothing to say is dropped without a note" do
      {_, notes} = Body.extract(auth_doc(header: ~s(<img src="x.png" alt="logo">)))
      assert notes == []
    end

    test "a footer holding a placeholder is kept as the last block of the body" do
      {fragment, []} = Body.extract(auth_doc())

      assert fragment =~ "Or paste this link:"
      assert fragment =~ "margin-top: 30px"
      assert String.ends_with?(String.trim_trailing(fragment), "</div>")
      {footer_at, _} = :binary.match(fragment, "Or paste this link")
      {button_at, _} = :binary.match(fragment, "Confirm My Account")
      assert footer_at > button_at
    end

    test "a footer with no placeholder is chrome: dropped, and its text is reported" do
      {fragment, notes} = Body.extract(auth_doc(footer: "<p>© 2026   Acme Ltd, Tallinn</p>"))

      refute fragment =~ "Acme Ltd"
      assert {:chrome_dropped, ["footer: © 2026 Acme Ltd, Tallinn"]} in notes
    end

    test "dropped header and footer are reported together in one note" do
      {_, notes} =
        Body.extract(auth_doc(header: "Acme", footer: "<p>Tallinn</p>"))

      assert [{:chrome_dropped, ["header: Acme", "footer: Tallinn"]}] = notes
    end
  end

  describe "extract/1 — falling back" do
    test "without a .header or .footer the whole body is kept, with a note" do
      doc = """
      <html><head><style>p { color: red; }</style></head>
      <body><div class="wrapper"><p>Hello {{name}}</p></div></body></html>
      """

      {fragment, notes} = Body.extract(doc)

      assert fragment =~ "Hello {{name}}"
      assert fragment =~ "wrapper"
      refute fragment =~ "<body"
      assert [{:body_fallback, [reason]}] = notes
      assert reason =~ ".header"
    end

    test "a header without a footer is a fallback too, never a guess" do
      doc = """
      <html><body><div><div class="header"><h1>T</h1></div><p>Body</p></div></body></html>
      """

      {fragment, [{:body_fallback, [reason]}]} = Body.extract(doc)
      assert reason =~ ".footer"
      assert fragment =~ "Body"
    end

    test "a header and footer that are not siblings are a fallback" do
      doc = """
      <html><body>
        <div class="a"><div class="header"><h1>T</h1></div><p>one</p></div>
        <p>two</p>
        <div class="footer"><p>{{x}}</p></div>
      </body></html>
      """

      {fragment, [{:body_fallback, [reason]}]} = Body.extract(doc)
      assert reason =~ "siblings"
      assert fragment =~ "one" and fragment =~ "two"
    end

    test "a document without <body> still yields what follows the head" do
      doc = ~s(<html><head><title>x</title></head><p class="x">Hi</p></html>)
      {fragment, [{:body_fallback, _}]} = Body.extract(doc)
      assert fragment =~ "Hi"
      refute fragment =~ "<title"
    end
  end

  describe "extract/1 — inlined styles" do
    test "a class rule becomes the element's style attribute" do
      {fragment, _} = Body.extract(auth_doc())

      assert fragment =~
               ~s(<div class="warning" style="background-color: #fef3c7; padding: 16px;">)
    end

    test "the button keeps its look" do
      {fragment, _} = Body.extract(auth_doc())

      assert fragment =~
               ~s(href="{{confirmation_url}}" class="button" style="display: inline-block;)

      assert fragment =~ "background-color: #3b82f6"
      assert fragment =~ "color: white"
    end

    test "an existing inline style wins over the rule" do
      css = ".p { margin: 1px; color: red; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <p class="p" style="color: blue">x</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<p class="p" style="margin: 1px; color: blue;">)
    end

    test "a higher specificity beats a later rule" do
      css = ".box .item { color: red; } .item { color: blue; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <div class="box"><span class="item">x</span></div>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<span class="item" style="color: red;">)
    end

    test "descendant selectors match through the ancestors the cut removed" do
      css = ".container p { color: green; } .content p { margin: 0; } td { padding: 5px; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="container"><div class="header"><h1>T</h1></div>
      <div class="content"><p>x</p><table><tr><td>y</td></tr></table></div>
      <div class="footer">{{u}}</div></div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<p style="color: green; margin: 0;">)
      assert fragment =~ ~s(<td style="padding: 5px;">)
    end

    test "a class beats any number of tag selectors" do
      css = "div div div div div div div div div div div p { color: red; } .x { color: blue; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <div><div><div><div><div><div><div><div><div><div><div>
      <p class="x">x</p>
      </div></div></div></div></div></div></div></div></div></div></div>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<p class="x" style="color: blue;">)
    end

    test "selectors that cannot be inlined are skipped, not misapplied" do
      css = """
      a:hover { color: red; }
      .a > .b { color: red; }
      #id { color: red; }
      * { color: red; }
      @media (max-width: 600px) { .a { color: red; } }
      .a { margin: 0; }
      /* .a { color: purple; } */
      """

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <div class="a"><span class="b" id="id">x</span></div>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<div class="a" style="margin: 0;">)
      assert fragment =~ ~s(<span class="b" id="id">)
      refute fragment =~ "red"
      refute fragment =~ "purple"
    end

    test "a selector list applies to each member" do
      css = ".x, .y { margin: 2px; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <i class="x">1</i><i class="y">2</i><i class="z">3</i>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<i class="x" style="margin: 2px;">)
      assert fragment =~ ~s(<i class="y" style="margin: 2px;">)
      assert fragment =~ ~s(<i class="z">)
    end

    test "a self-closing element keeps its slash" do
      css = ".r { border: 0; }"

      doc = """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      <hr class="r" /><br class="r">
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<hr class="r" style="border: 0;" />)
      assert fragment =~ ~s(<br class="r" style="border: 0;">)
    end
  end

  describe "extract/1 — tokenizer" do
    test "an unquoted value ending in / is not a self-closing tag" do
      doc = """
      <html><head><style>a { color: red; }</style></head><body>
      <div class="header"><h1>T</h1></div>
      <p><a href=https://x.com/>go</a> <a href=/p/ >two</a> <br/><img src="a"/></p>
      <div class="footer">{{u}}</div></body></html>
      """

      assert {fragment, []} = Body.extract(doc)
      assert fragment =~ ~s(<a href=https://x.com/ style="color: red;">go</a>)
      assert fragment =~ ~s(<a href=/p/ style="color: red;">two</a>)
      assert fragment =~ ~s(<br/><img src="a"/>)
    end

    test "a > inside a quoted attribute does not end the tag" do
      doc = """
      <html><body>
      <div class="header"><h1>T</h1></div>
      <p title="a > b" data-x='1 > 0'>text {{x}}</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ ~s(<p title="a > b" data-x='1 > 0'>text {{x}}</p>)
    end

    test "comments, entities and a stray < in text are kept verbatim" do
      doc = """
      <html><body>
      <div class="header"><h1>T</h1></div>
      <!-- keep me --><p>1 < 2 &amp; 3 &gt; 2 &nbsp;</p>
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ "<!-- keep me -->"
      assert fragment =~ "1 < 2 &amp; 3 &gt; 2 &nbsp;"
    end

    test "an unclosed <p> or <li> does not upset the cut" do
      doc = """
      <html><body><div class="header"><h1>T</h1></div>
      <ul><li>one<li>two</ul><p>loose
      <div class="footer">{{u}}</div></body></html>
      """

      {fragment, []} = Body.extract(doc)
      assert fragment =~ "<li>one<li>two</ul>"
      assert fragment =~ "loose"
    end

    test "a style block with a < in a comment, and uppercase tags, are handled" do
      doc = """
      <HTML><HEAD><STYLE>/* a < b */ .p { margin: 3px; }</STYLE></HEAD><BODY>
      <DIV CLASS="header"><H1>T</H1></DIV>
      <P class="p">x</P>
      <DIV class="footer">{{u}}</DIV></BODY></HTML>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<P class="p" style="margin: 3px;">x</P>)
    end

    test "an unterminated tag or comment does not hang or crash" do
      assert {_, _} = Body.extract("<html><body><div class=\"header\"><h1>T</h1></div><p <!-- ")
      assert {_, _} = Body.extract("<html><body><div class=\"header")
    end
  end

  describe "extract/1 — nothing outside the header and footer is lost" do
    defp seed_like(parts) do
      """
      <!DOCTYPE html>
      <html><head><style>.header { text-align: center; } .footer { font-size: 14px; }</style></head>
      <body>
      #{parts[:before]}
      <div class="container">
        #{parts[:preheader]}
        <div class="header"><h1>Title</h1></div>
        #{parts[:middle] || "<p>Hi {{user_email}}</p>"}
        <div class="footer"><p><a href="{{confirmation_url}}">{{confirmation_url}}</a></p></div>
        #{parts[:after_footer]}
      </div>
      #{parts[:after_container]}
      </body></html>
      """
    end

    test "a preheader before the header is kept, ahead of it" do
      {fragment, notes} = Body.extract(seed_like(preheader: "<p>Preview: {{preview_text}}</p>"))

      assert notes == []
      {pre, _} = :binary.match(fragment, "{{preview_text}}")
      {title, _} = :binary.match(fragment, "Title")
      assert pre < title
    end

    test "text after the footer, inside the container, is kept, after it" do
      {fragment, notes} =
        Body.extract(seed_like(after_footer: "<p>Unsubscribe: {{unsubscribe_url}}</p>"))

      assert notes == []
      {unsub, _} = :binary.match(fragment, "{{unsubscribe_url}}")
      {confirm, _} = :binary.match(fragment, "{{confirmation_url}}")
      assert unsub > confirm
    end

    test "text outside the container, before and after it, is kept" do
      {fragment, _} =
        Body.extract(
          seed_like(before: "<p>Top {{top}}</p>", after_container: "<p>Bottom {{bottom}}</p>")
        )

      assert fragment =~ "Top {{top}}"
      assert fragment =~ "Bottom {{bottom}}"
      refute fragment =~ ~s(class="container")
    end

    test "an earlier element that carries the footer class is body, not the footer" do
      {fragment, notes} =
        Body.extract(
          seed_like(middle: ~s(<p class="footer note">Tip: {{tip}}</p><p>Hi {{user_email}}</p>))
        )

      assert notes == []
      assert fragment =~ "Tip: {{tip}}"
      assert fragment =~ "Hi {{user_email}}"
      assert fragment =~ "{{confirmation_url}}"
    end

    test "a footer-classed element without a placeholder before the real footer is body" do
      {fragment, notes} =
        Body.extract(
          seed_like(middle: ~s(<p class="footer">Note: nothing here</p><p>Hi {{user_email}}</p>))
        )

      # Taken for the footer it would be dropped as decoration, with a note.
      assert notes == []
      assert fragment =~ "Note: nothing here"
      assert fragment =~ "{{confirmation_url}}"
    end

    test "every placeholder of the whole body survives, wherever it sat" do
      doc =
        seed_like(
          before: "<p>{{a}}</p>",
          preheader: "<p>{{b}}</p>",
          middle: "<p>{{c}} {{{d}}}</p>",
          after_footer: "<p>{{e}}</p>",
          after_container: "<p>{{f}}</p>"
        )

      {fragment, _} = Body.extract(doc)
      [_, body] = Regex.run(~r/<body>(.*)<\/body>/s, doc)
      assert MapSet.subset?(placeholders(body), placeholders(fragment))
    end
  end

  describe "extract/1 — header and footer keep rules, continued" do
    test "a header holding a placeholder but no heading is content, kept" do
      {fragment, notes} = Body.extract(auth_doc(header: "<div>Invoice {{invoice_number}}</div>"))

      assert fragment =~ "Invoice {{invoice_number}}"
      assert notes == []
    end

    test "a footer whose only placeholder is in an attribute is kept" do
      {fragment, notes} =
        Body.extract(auth_doc(footer: ~s(<img src="{{logo_url}}" alt="Acme"><p>Acme</p>)))

      assert fragment =~ ~s(src="{{logo_url}}")
      assert notes == []
    end

    test "a kept header takes no descendant rule written for its background" do
      css =
        ".header h1 { color: white; font-size: 28px; } .header { color: white; text-align: center; }"

      {fragment, _} = Body.extract(auth_doc(css: css))

      assert fragment =~ "<h1>Welcome! Please confirm your account</h1>"
      refute fragment =~ "white"
      assert fragment =~ "text-align: center"
    end

    test "a header's own inline style wins over the stylesheet for what is kept" do
      doc = """
      <html><head><style>.header { text-align: center; margin-bottom: 30px; }</style></head><body>
      <div class="header" style="text-align: left; background: red"><h1>T</h1></div>
      <p>x</p><div class="footer">{{u}}</div></body></html>
      """

      {fragment, _} = Body.extract(doc)
      assert fragment =~ ~s(<div style="text-align: left; margin-bottom: 30px;">)
      refute fragment =~ "red"
    end
  end

  describe "extract/1 — inline styles are kept whole" do
    defp styled(css, element) do
      """
      <html><head><style>#{css}</style></head><body>
      <div class="header"><h1>T</h1></div>
      #{element}
      <div class="footer">{{u}}</div></body></html>
      """
    end

    test "a placeholder standing in for declarations survives, after the rule's own" do
      {fragment, _} =
        Body.extract(
          styled(".b { padding: 1px; }", ~s(<a class="b" style="{{button_style}}">x</a>))
        )

      assert fragment =~ ~s(<a class="b" style="padding: 1px; {{button_style}};">)
    end

    test "a triple-brace placeholder in the style attribute survives" do
      {fragment, _} =
        Body.extract(
          styled(
            ".b { padding: 1px; }",
            ~s(<a class="b" style="color: red; {{{extra_css}}}">x</a>)
          )
        )

      assert fragment =~ "{{{extra_css}}}"
      assert fragment =~ "color: red;"
    end

    test "a ; inside quotes or parentheses does not cut a value" do
      img = ~s[<i class="b" style="background: url('data:image/png;base64,AAAA') no-repeat">x</i>]
      {fragment, _} = Body.extract(styled(".b { margin: 0; }", img))

      assert fragment =~ "background: url('data:image/png;base64,AAAA') no-repeat;"
      assert fragment =~ "margin: 0;"
    end

    test "a ; inside quotes alone, and inside parentheses alone, does not cut a value" do
      quoted = ~s[<i class="b" style="content: 'a;b'">x</i>]
      unquoted = ~s[<i class="b" style="background: url(data:image/png;base64,CCCC)">y</i>]
      {fragment, _} = Body.extract(styled(".b { margin: 0; }", quoted <> unquoted))

      assert fragment =~ "content: 'a;b';"
      assert fragment =~ "background: url(data:image/png;base64,CCCC);"
    end

    test "a ; inside a stylesheet value does not cut it either" do
      css = ".b { background: url(\"data:image/png;base64,BBBB\"); color: red; }"
      {fragment, _} = Body.extract(styled(css, ~s(<i class="b">x</i>)))

      assert fragment =~ "background: url('data:image/png;base64,BBBB');"
      assert fragment =~ "color: red;"
    end

    test "a placeholder inside a rule does not end it, and the next rule still applies" do
      css = ".b { background-color: {{accent_color}}; padding: 4px } .w { color: red }"
      {fragment, notes} = Body.extract(styled(css, ~s(<i class="b">x</i><i class="w">y</i>)))

      assert fragment =~
               ~s(<i class="b" style="background-color: {{accent_color}}; padding: 4px;">)

      assert fragment =~ ~s(<i class="w" style="color: red;">)
      assert notes == []
    end

    test "a triple-brace placeholder between rules is skipped, the rules around it kept, and it is reported" do
      css = ".b { margin: 1px } {{{extra_css}}} .w { color: red }"
      {fragment, notes} = Body.extract(styled(css, ~s(<i class="b">x</i><i class="w">y</i>)))

      assert fragment =~ ~s(<i class="b" style="margin: 1px;">)
      assert fragment =~ ~s(<i class="w" style="color: red;">)
      assert [{:style_placeholder, ["extra_css"]}] = notes
    end

    test "a double-brace placeholder between rules does not swallow the rule after it" do
      css = ".b { margin: 1px } {{extra_css}} .w { color: red }"
      {fragment, notes} = Body.extract(styled(css, ~s(<i class="w">y</i>)))

      assert fragment =~ ~s(<i class="w" style="color: red;">)
      assert [{:style_placeholder, ["extra_css"]}] = notes
    end

    test "a triple-brace placeholder standing in for declarations is reported when it cannot be carried" do
      css = ".b { margin: 1px; {{{extra_css}}} }"
      {_, notes} = Body.extract(styled(css, ~s(<i class="b">x</i>)))
      assert [{:style_placeholder, ["extra_css"]}] = notes
    end

    test "a } inside a quoted string does not end a rule" do
      css = ~s[.b { content: "}"; margin: 2px } .w { color: red }]
      {fragment, _} = Body.extract(styled(css, ~s(<i class="b">x</i><i class="w">y</i>)))

      assert fragment =~ ~s(<i class="b" style="content: '}'; margin: 2px;">)
      assert fragment =~ ~s(<i class="w" style="color: red;">)
    end

    test "an at-rule without a block does not swallow the rule after it" do
      css = ~s[@charset "utf-8"; @import url(x.css); .b { margin: 4px; }]
      {fragment, _} = Body.extract(styled(css, ~s(<i class="b">x</i>)))
      assert fragment =~ ~s(<i class="b" style="margin: 4px;">)
    end

    test "!important is not honoured: it stays in the value, the inline declaration still wins" do
      css = ".b { color: red !important; margin: 1px; }"
      {fragment, _} = Body.extract(styled(css, ~s(<i class="b" style="color: blue">x</i>)))
      assert fragment =~ ~s(<i class="b" style="margin: 1px; color: blue;">)
    end

    test "a quote-aware tag scan applies the rule to the element after a > in an attribute" do
      {fragment, _} =
        Body.extract(
          styled(".b { margin: 7px; }", ~s(<p class="b" title="a > b">x</p><i class="b">y</i>))
        )

      assert fragment =~ ~s(<p class="b" title="a > b" style="margin: 7px;">x</p>)
      assert fragment =~ ~s(<i class="b" style="margin: 7px;">y</i>)
    end

    test "a script is verbatim, and what looks like a footer inside it is not one" do
      script = ~s(<script>var s = '<div class="footer">{{x}}</div>';</script>)
      {fragment, notes} = Body.extract(styled(".b { margin: 7px; }", script <> "<p>after</p>"))

      assert notes == []
      assert fragment =~ script
      assert fragment =~ "<p>after</p>"
    end
  end

  describe "extract/1 — bytes" do
    test "multibyte whitespace at the start of a line is left alone, and the result is valid UTF-8" do
      lines = "\u2003\u2003em space line\n  \u3000ideographic line {{x}}\n\u00A0nbsp line"

      {fragment, _} =
        Body.extract(auth_doc(greeting: "Hi</p><p>" <> String.replace(lines, "\n", "<br>\n")))

      assert String.valid?(fragment)
      assert fragment =~ "\u2003\u2003em space line"
      assert fragment =~ "\u3000ideographic line {{x}}"
      assert fragment =~ "\u00A0nbsp line"
    end

    test "text inside <pre> keeps its spaces and line breaks exactly" do
      pre = "<pre>line  one\n      indented   two\n\n\n\nafter blanks   </pre>"
      {fragment, _} = Body.extract(auth_doc(greeting: "Hi</p>" <> pre <> "<p>"))

      assert fragment =~ pre
    end

    test "CRLF documents are cut the same way" do
      doc = String.replace(auth_doc(), "\n", "\r\n")
      {fragment, notes} = Body.extract(doc)

      assert notes == []
      assert fragment =~ "Hi {{user_email}},"
      refute fragment =~ "<style"
    end
  end

  describe "extract/1 — large and hostile input" do
    # Each of these took tens of seconds when ancestors were rescanned per
    # element; now they are a handful of passes.
    defp timed(fun) do
      {micros, result} = :timer.tc(fun)
      {div(micros, 1000), result}
    end

    test "a megabyte of ordinary email stays in seconds" do
      rows =
        String.duplicate(
          ~s(<p class="b">Row {{x}} with <a href="{{u}}">a link</a> and text.</p>\n),
          16_000
        )

      doc = """
      <html><head><style>.b { margin: 0; } .b a { color: red; } p { padding: 1px; }</style></head><body>
      <div class="container"><div class="header"><h1>T</h1></div>#{rows}<div class="footer">{{u}}</div></div>
      </body></html>
      """

      assert byte_size(doc) > 1_000_000
      {ms, {fragment, notes}} = timed(fn -> Body.extract(doc) end)

      assert notes == []
      assert fragment =~ ~s(<p class="b" style="padding: 1px; margin: 0;">)
      assert ms < 8_000, "took #{ms} ms"
    end

    test "thousands of nested elements" do
      doc =
        "<html><body><div class=\"header\"><h1>T</h1></div>" <>
          String.duplicate("<div>", 4_000) <>
          "x" <>
          String.duplicate("</div>", 4_000) <> "<div class=\"footer\">{{u}}</div></body></html>"

      {ms, {fragment, _}} = timed(fn -> Body.extract(doc) end)
      assert fragment =~ "x"
      assert ms < 5_000, "took #{ms} ms"
    end

    test "thousands of style blocks" do
      styles = String.duplicate("<style>.a { margin: 1px; }</style>", 4_000)

      doc =
        "<html><head>#{styles}</head><body><div class=\"header\"><h1>T</h1></div><p class=\"a\">x</p><div class=\"footer\">{{u}}</div></body></html>"

      {ms, {fragment, _}} = timed(fn -> Body.extract(doc) end)
      assert fragment =~ "margin: 1px"
      assert ms < 5_000, "took #{ms} ms"
    end

    test "thousands of tags that never close" do
      doc =
        ~s(<html><body><div class="header"><h1>T</h1></div><p>x</p><div class="footer">{{u}}</div>) <>
          String.duplicate("<a b ", 20_000)

      {ms, {fragment, _}} = timed(fn -> Body.extract(doc) end)
      assert fragment =~ "<p>x</p>"
      assert ms < 5_000, "took #{ms} ms"
    end

    test "a stylesheet comment that never closes" do
      css = ".a { margin: 1px; } /*" <> String.duplicate("/* x ", 20_000)

      doc =
        "<html><head><style>#{css}</style></head><body><div class=\"header\"><h1>T</h1></div><p class=\"a\">x</p><div class=\"footer\">{{u}}</div></body></html>"

      {ms, {fragment, _}} = timed(fn -> Body.extract(doc) end)
      assert fragment =~ "margin: 1px"
      assert ms < 5_000, "took #{ms} ms"
    end

    test "thousands of stray closing tags" do
      doc =
        "<html><body><div class=\"header\"><h1>T</h1></div>" <>
          String.duplicate("<span>", 20_000) <>
          String.duplicate("</i>", 20_000) <> "<div class=\"footer\">{{u}}</div></body></html>"

      {ms, _} = timed(fn -> Body.extract(doc) end)
      assert ms < 5_000, "took #{ms} ms"
    end
  end

  describe "document?/1 agrees with core's own test" do
    @samples [
      "<!DOCTYPE html><html></html>",
      "\u00A0<!doctype html>",
      "\f<html>",
      "\u2003<html lang=en>",
      "<?php echo 1; ?><html>",
      "<?xml version=\"1.0\"?><html>",
      "<!-- c --> <html>",
      "<p>x</p><html>",
      "<htmlish>"
    ]

    test "on the shapes that tripped the first version" do
      if Code.ensure_loaded?(PhoenixKit.Email.Layout) do
        for sample <- @samples do
          assert Body.document?(sample) == Layout.document?(sample),
                 "disagrees on #{inspect(sample)}"
        end
      end
    end

    test "its own fallback rule gives the right answer on the plain cases" do
      assert Body.local_document?("<!DOCTYPE html><html></html>")
      assert Body.local_document?("\uFEFF \n<!-- c --><?xml version=\"1.0\"?>\n<html>")
      refute Body.local_document?("<p>x</p>")
      refute Body.local_document?("<htmlish>")
    end
  end
end
