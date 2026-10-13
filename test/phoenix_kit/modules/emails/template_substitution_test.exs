defmodule PhoenixKit.Modules.Emails.TemplateSubstitutionTest do
  @moduledoc """
  `Template.extract_variables/1` and `Template.substitute_variables/3` read
  placeholders with one tokenizer, under the rules of
  `PhoenixKit.Templates.Substitution` (`phoenix_kit_templates` >= 0.2.0), so a
  database row and a file override render the same content the same way:

    * `{{ name }}` is `{{name}}`;
    * `{{name}}` is HTML-escaped in `html_body`, `{{{name}}}` is inserted raw;
    * `subject` and `text_body` are plain text and never escaped;
    * a name is an identifier — anything else is literal text;
    * an unbound placeholder is left exactly as written;
    * a value is never itself scanned for placeholders.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.Templates

  defp template(html, opts \\ []) do
    %Template{
      subject: %{"en" => Keyword.get(opts, :subject, "")},
      html_body: %{"en" => html},
      text_body: %{"en" => Keyword.get(opts, :text, "")}
    }
  end

  defp render(content, variables) do
    %{html_body: html} = Template.substitute_variables(template(content), variables)
    html
  end

  describe "escaping in html_body (#43)" do
    test "{{var}} escapes <, >, &, \" and '" do
      assert render(~s(<p>{{name}}</p>), %{"name" => ~s(<b>A&B</b> "q" 'a')}) ==
               "<p>&lt;b&gt;A&amp;B&lt;/b&gt; &quot;q&quot; &#39;a&#39;</p>"
    end

    test "a script tag in a value arrives as text" do
      out = render("<p>Hello {{user_name}}</p>", %{"user_name" => "<script>alert(1)</script>"})

      refute out =~ "<script>"
      assert out == "<p>Hello &lt;script&gt;alert(1)&lt;/script&gt;</p>"
    end

    test "an attribute cannot be broken out of" do
      out = render(~s(<a href="{{url}}">x</a>), %{"url" => ~s(https://e.x/?a=1&b=" onclick="x)})

      assert out == ~s(<a href="https://e.x/?a=1&amp;b=&quot; onclick=&quot;x">x</a>)
    end

    test "an already-escaped entity is escaped again — a value is data, not markup" do
      assert render("{{name}}", %{"name" => "Tom &amp; Jerry"}) == "Tom &amp;amp; Jerry"
    end

    test "{{{var}}} is inserted raw" do
      assert render("<table>{{{rows}}}</table>", %{"rows" => "<tr><td>1</td></tr>"}) ==
               "<table><tr><td>1</td></tr></table>"
    end

    test "{{{ var }}} with inner whitespace is raw too" do
      assert render("{{{ rows }}}", %{"rows" => "<tr></tr>"}) == "<tr></tr>"
    end

    test "the same variable can be escaped in one place and raw in another" do
      assert render("{{v}}|{{{v}}}", %{"v" => "<i>"}) == "&lt;i&gt;|<i>"
    end

    test "subject and text_body are never escaped, in either syntax" do
      t =
        template("{{v}}",
          subject: "Re: {{v}} / {{{v}}}",
          text: "Text {{v}} / {{{v}}}"
        )

      result = Template.substitute_variables(t, %{"v" => "<A & B>"})

      assert result.subject == "Re: <A & B> / <A & B>"
      assert result.text_body == "Text <A & B> / <A & B>"
      assert result.html_body == "&lt;A &amp; B&gt;"
    end

    test "a variable known to carry rendered HTML stays raw even in double braces" do
      # Rows written before {{{...}}} existed say {{line_items_html}}; the V3
      # migration rewrites them, but a send between deploying this code and
      # running that migration must not show an escaped table.
      for name <- Template.raw_html_variables() do
        assert render("<table>{{#{name}}}</table>", %{name => "<tr><td>1</td></tr>"}) ==
                 "<table><tr><td>1</td></tr></table>"
      end
    end

    test "scalars that are not strings are rendered and escaped like strings" do
      assert render("{{n}} {{f}} {{b}} {{a}} {{nil}}", %{
               "n" => 42,
               "f" => 1.5,
               "b" => true,
               "a" => :"x<y",
               "nil" => nil
             }) == "42 1.5 true x&lt;y "

      assert render("{{d}} {{dec}}", %{"d" => ~D[2026-10-08], "dec" => Decimal.new("9.90")}) ==
               "2026-10-08 9.90"
    end
  end

  describe "rejecting values that are not scalars (#44)" do
    for {label, value} <- [
          {"map", quote(do: %{"a" => 1})},
          {"list", quote(do: ["a", "b"])},
          {"tuple", quote(do: {:ok, 1})},
          {"struct without String.Chars", quote(do: %Template{})}
        ] do
      test "a #{label} raises an ArgumentError that names the variable" do
        error =
          assert_raise ArgumentError, fn ->
            render("<p>{{items}}</p>", %{"items" => unquote(value)})
          end

        assert error.message =~ ~s("items")
        assert error.message =~ "must be a string"
      end
    end

    test "the message does not echo the value" do
      error =
        assert_raise ArgumentError, fn ->
          render("{{secret}}", %{"secret" => %{"token" => "s3cr3t-token"}})
        end

      refute error.message =~ "s3cr3t-token"
    end

    test "a non-scalar value the content never uses is not an error" do
      assert render("<p>{{name}}</p>", %{"name" => "A", "unused" => %{"x" => 1}}) == "<p>A</p>"
    end
  end

  describe "one parser for extraction and substitution (#44)" do
    test "{{ name }} is extracted as name and substituted" do
      t = template("<p>{{ name }} {{name}} {{  name  }}</p>")

      assert Template.extract_variables(t) == ["name"]
      assert render("<p>{{ name }} {{name}} {{  name  }}</p>", %{"name" => "A"}) == "<p>A A A</p>"
    end

    test "{{{name}}} is extracted as name, not {name" do
      assert Template.extract_variables(template("{{{rows}}}")) == ["rows"]
    end

    test "a name that is not an identifier is literal text, in both functions" do
      for content <- ["{{user.name}}", "{{user-name}}", "{{1st}}", "{{a b}}", "{{}}", "{{ }}"] do
        assert Template.extract_variables(template(content)) == [], content

        bound = %{"user.name" => "X", "user-name" => "X", "1st" => "X", "a b" => "X", "" => "X"}
        assert render(content, bound) == content, content
      end
    end

    test "unclosed and half-closed braces are literal text" do
      for content <- ["{{name", "name}}", "{{name}", "{name}}", "{ {name} }"] do
        assert Template.extract_variables(template(content)) == [], content
        assert render(content, %{"name" => "X"}) == content, content
      end
    end

    test "nested and unbalanced brace runs follow the left-to-right rule" do
      for {content, expected} <- [
            {"{{{{x}}}}", "{V}"},
            {"{{{x}}", "{V"},
            {"{{x}}}", "V}"},
            {"{ {{x}} }", "{ V }"}
          ] do
        assert Template.extract_variables(template(content)) == ["x"], content
        assert render(content, %{"x" => "V"}) == expected, content
      end
    end

    test "CSS braces in html_body are untouched" do
      css = "<style>body { margin: 0 } @media (max-width: 600px) { p { color: red } }</style>"

      assert Template.extract_variables(template(css)) == []
      assert render(css <> "{{x}}", %{"x" => "V"}) == css <> "V"
    end

    test "an unbound placeholder is left exactly as written" do
      assert render("{{ missing }} {{{ raw }}} {{x}}", %{"x" => "V"}) ==
               "{{ missing }} {{{ raw }}} V"
    end

    test "a value is never scanned for placeholders" do
      # The old String.replace loop ran once per variable over the growing
      # output, so a value carrying "{{other}}" got "other" substituted into
      # it — a customer-controlled name could pull in any other variable.
      assert render("{{a}} {{b}}", %{"a" => "{{b}}", "b" => "<i>"}) ==
               "{{b}} &lt;i&gt;"
    end

    test "atom and string keys are equivalent" do
      assert render("{{a}} {{{b}}}", %{a: "<1>", b: "<2>"}) == "&lt;1&gt; <2>"
    end

    test "every extracted name is substituted once bound — the two never disagree" do
      contents = [
        "{{a}} {{ b }} {{{c}}} {{{ d }}}",
        "{{{{e}}}} {{{f}} {{g}}} { {{h}} }",
        "{{i.j}} {{k-l}} {{m n}} {{o",
        "<style>p { x: 1 }</style>{{p}}",
        "{{_q}} {{Q9}} {{9q}}"
      ]

      for content <- contents do
        names = Template.extract_variables(template(content))
        rendered = render(content, Map.new(names, &{&1, "X"}))

        assert Template.extract_variables(template(rendered)) == [],
               "#{inspect(content)} left a placeholder behind: #{inspect(rendered)}"
      end
    end

    test "extraction reads every locale of every field, sorted and unique" do
      t = %Template{
        subject: %{"en" => "{{b}}", "uk" => "{{ a }}"},
        html_body: %{"en" => "{{{c}}}"},
        text_body: "{{b}} {{d}}"
      }

      assert Template.extract_variables(t) == ["a", "b", "c", "d"]
    end
  end

  describe "Templates.render_template/3" do
    test "atom keys are not reported as missing" do
      log =
        capture_log(fn ->
          result = Templates.render_template(template("<p>{{ name }}</p>"), %{name: "A"})
          assert result.html_body == "<p>A</p>"
        end)

      refute log =~ "missing required variables"
      refute log =~ "unused variables"
      refute log =~ "unreplaced"
    end

    test "a value containing braces is not mistaken for an unreplaced placeholder" do
      log =
        capture_log(fn ->
          Templates.render_template(template("<p>{{a}}</p>"), %{"a" => "{{b}}"})
        end)

      refute log =~ "unreplaced"
    end

    test "CSS braces are not mistaken for an unreplaced placeholder" do
      log =
        capture_log(fn ->
          Templates.render_template(template("<style>p {{ x: 1 }}</style>{{a}}"), %{"a" => "1"})
        end)

      refute log =~ "unreplaced"
    end

    test "a genuinely unbound placeholder is still reported, by field" do
      log =
        capture_log(fn ->
          Templates.render_template(template("<p>{{ gone }}</p>", text: "ok"), %{})
        end)

      assert log =~ "missing required variables: gone"
      assert log =~ "unreplaced variables in: html_body"
      refute log =~ "text_body"
    end
  end

  describe "seeded system templates" do
    test "every raw-HTML variable they use is written with triple braces" do
      for %{name: name, html_body: html_body} <- Templates.default_system_templates(),
          {_locale, content} <- html_body,
          raw <- Template.raw_html_variables() do
        refute content =~ ~r/(?<!\{)\{\{\s*#{raw}\s*\}\}(?!\})/,
               "#{name} still writes {{#{raw}}} in double braces"
      end

      invoice = Enum.find(Templates.default_system_templates(), &(&1.name == "billing_invoice"))
      assert invoice.html_body["en"] =~ "{{{line_items_html}}}"
    end

    test "a seeded billing template renders line items raw and the customer name escaped" do
      for name <- ["billing_invoice", "billing_receipt"] do
        attrs = Enum.find(Templates.default_system_templates(), &(&1.name == name))
        t = struct(Template, Map.take(attrs, [:subject, :html_body, :text_body]))

        %{html_body: html} =
          Template.substitute_variables(t, %{
            "line_items_html" => "<tr><td>Widget</td></tr>",
            "user_name" => "Ann <Admin> & Co"
          })

        assert html =~ "<tr><td>Widget</td></tr>", name
        assert html =~ "Ann &lt;Admin&gt; &amp; Co", name
        refute html =~ "Ann <Admin>", name
      end
    end
  end
end
