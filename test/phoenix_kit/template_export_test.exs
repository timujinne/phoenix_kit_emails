defmodule PhoenixKit.Modules.Emails.TemplateExportTest do
  @moduledoc """
  Which stored templates become override files, and what those files are
  called — the two questions the move off the templates table turns on.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates

  defp template(attrs) do
    struct(
      %Template{
        name: "register",
        is_system: true,
        subject: %{"en" => "Confirm your account"},
        text_body: %{"en" => "Hi there"},
        html_body: %{}
      },
      attrs
    )
  end

  defp shipped,
    do: [
      %{
        name: "register",
        subject: %{"en" => "Confirm your account"},
        text_body: %{"en" => "Hi there"},
        html_body: %{}
      }
    ]

  defp invoice(html, subject \\ "Invoice") do
    template(%{
      name: "billing_invoice",
      subject: %{"en" => subject},
      text_body: %{"en" => "{{line_items_html}} as text, never rewritten"},
      html_body: %{"en" => html}
    })
  end

  defp invoice_shipped do
    [
      %{
        name: "billing_invoice",
        subject: %{"en" => "shipped subject"},
        text_body: %{"en" => "shipped text"},
        html_body: %{"en" => "shipped html"}
      }
    ]
  end

  defp html_file(plan) do
    Enum.find_value(plan.files, fn {path, content} ->
      if String.ends_with?(path, "html.html"), do: content
    end)
  end

  defp file(plan, filename) do
    Enum.find_value(plan.files, fn {path, content} ->
      if String.ends_with?(path, filename), do: content
    end)
  end

  describe "edited?/2" do
    test "an untouched row is not edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})
      refute TemplateExport.edited?(template(%{}), by_name)
    end

    test "a row whose content differs is edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})

      assert TemplateExport.edited?(template(%{subject: %{"en" => "Please confirm"}}), by_name)
      assert TemplateExport.edited?(template(%{text_body: %{"en" => "Custom"}}), by_name)
      assert TemplateExport.edited?(template(%{html_body: %{"en" => "<p>x</p>"}}), by_name)
    end

    test "a row gaining a translation is edited" do
      # Adding a locale is a customization worth carrying out, even though the
      # English content the package shipped is untouched.
      by_name = Map.new(shipped(), &{&1.name, &1})
      extra = template(%{subject: %{"en" => "Confirm your account", "uk" => "Підтвердіть"}})

      assert TemplateExport.edited?(extra, by_name)
    end

    test "a name this package does not ship counts as edited" do
      # Nothing is known about what it should look like, and a file too many is
      # recoverable where a dropped edit is not.
      assert TemplateExport.edited?(template(%{name: "something_bespoke"}), %{})
    end

    test "metadata differences do not make a template edited" do
      by_name = Map.new(shipped(), &{&1.name, &1})
      busy = template(%{usage_count: 900, slug: "renamed", status: "draft"})

      refute TemplateExport.edited?(busy, by_name)
    end
  end

  describe "files_for/2 — the locale rule" do
    test "the fallback locale is written WITHOUT a locale in the filename" do
      # This is the load-bearing one. The stored map's fallback is what every
      # recipient without their own translation receives; core falls through to
      # the locale-LESS file. Writing it as subject.en.txt would silently drop
      # the operator's customization for every non-English recipient.
      files = TemplateExport.files_for(template(%{}), "out")

      assert {"out/register/subject.txt", "Confirm your account"} in files
      refute Enum.any?(files, fn {path, _} -> path =~ "subject.en.txt" end)
    end

    test "every other locale carries its code" do
      t = template(%{subject: %{"en" => "Confirm", "uk" => "Підтвердіть", "de" => "Bestätigen"}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/subject.txt" in paths
      assert "out/register/subject.uk.txt" in paths
      assert "out/register/subject.de.txt" in paths
    end

    test "without an English key the lowest-sorting locale is the fallback" do
      t = template(%{subject: %{"uk" => "Підтвердіть", "de" => "Bestätigen"}, text_body: %{}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/subject.txt" in paths
      assert "out/register/subject.uk.txt" in paths
      refute "out/register/subject.de.txt" in paths
    end

    test "html goes to .html, subject and text to .txt" do
      t = template(%{html_body: %{"en" => "<p>hi</p>"}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert "out/register/html.html" in paths
      assert "out/register/subject.txt" in paths
      assert "out/register/text.txt" in paths
    end

    test "a part with no content produces no file" do
      t = template(%{html_body: %{"en" => ""}, text_body: %{"en" => nil}})
      paths = t |> TemplateExport.files_for("out") |> Enum.map(&elem(&1, 0))

      assert paths == ["out/register/subject.txt"]
    end
  end

  describe "plan/3" do
    test "separates edited, untouched and operator-authored rows" do
      edited = template(%{name: "register", subject: %{"en" => "Please confirm"}})
      untouched = template(%{})
      authored = template(%{name: "newsletter_wrapper", is_system: false})

      plan = TemplateExport.plan([edited, untouched, authored], shipped(), out: "out")

      assert [%Template{subject: %{"en" => "Please confirm"}}] = plan.edited
      assert [%Template{subject: %{"en" => "Confirm your account"}}] = plan.untouched
      assert [%Template{name: "newsletter_wrapper"}] = plan.authored
    end

    test "only edited rows produce files" do
      plan =
        TemplateExport.plan([template(%{}), template(%{name: "x", is_system: false})], shipped())

      assert plan.files == []
    end
  end

  describe "plan/3 — raw HTML variables" do
    test "rewrites a known raw-html variable to triple braces when supported" do
      html = "<p>{{user_name}}</p>{{line_items_html}}<p>{{total}}</p>"

      plan =
        TemplateExport.plan([invoice(html)], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "<p>{{user_name}}</p>{{{line_items_html}}}<p>{{total}}</p>"
      assert [%{path: path, kind: :rewritten, names: ["line_items_html"]}] = plan.notices
      assert String.ends_with?(path, "html.html")
    end

    test "never rewrites subject, even when it contains the same name verbatim" do
      # The mutation this guards against: a refactor that applies the rewrite
      # to every part instead of gating it on the `.html` path suffix. Putting
      # the exact placeholder in `subject` too, and asserting it byte-for-byte,
      # is what would actually catch that — a plain subject with no
      # placeholder in it would pass whether or not the gate existed.
      plan =
        TemplateExport.plan(
          [invoice("plain html", "{{line_items_html}} in the subject")],
          invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert file(plan, "subject.txt") == "{{line_items_html}} in the subject"
      refute Enum.any?(plan.notices, &String.ends_with?(&1.path, "subject.txt"))
    end

    test "never rewrites text, even when it contains the same name verbatim" do
      plan =
        TemplateExport.plan([invoice("plain html")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert file(plan, "text.txt") == "{{line_items_html}} as text, never rewritten"
      refute Enum.any?(plan.notices, &String.ends_with?(&1.path, "text.txt"))
    end

    test "is idempotent — an already-triple-brace placeholder is left alone" do
      plan =
        TemplateExport.plan([invoice("{{{line_items_html}}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "{{{line_items_html}}}"
      assert plan.notices == []
    end

    test "is idempotent on a part that mixes the double and triple form of the same name" do
      # The naive alternative — a blind String.replace("{{name}}", "{{{name}}}")
      # over the whole content — would also match the double-brace substring
      # sitting inside the already-triple placeholder and stack an extra brace
      # on it (turning {{{x}}} into {{{{x}}}}). The regex-based rewrite in
      # rewrite_raw_html/3 does not have that failure mode because it matches
      # each placeholder occurrence once, but nothing before this test pinned
      # that down against a future rewrite of the implementation.
      plan =
        TemplateExport.plan(
          [invoice("{{line_items_html}} {{{line_items_html}}}")],
          invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "{{{line_items_html}}} {{{line_items_html}}}"
    end

    test "leaves double braces and warns when the loaded templates version is too old" do
      plan =
        TemplateExport.plan([invoice("{{line_items_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: false
        )

      assert html_file(plan) == "{{line_items_html}}"
      assert [%{kind: :needs_manual_rewrite, names: ["line_items_html"]}] = plan.notices
    end

    test "warns about an unrecognized _html placeholder and leaves it untouched" do
      plan =
        TemplateExport.plan([invoice("{{mystery_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert html_file(plan) == "{{mystery_html}}"
      assert [%{kind: :unknown_placeholder, names: ["mystery_html"]}] = plan.notices
    end

    test "an unrecognized _html placeholder's notice carries the plan's own raw_html_supported flag" do
      # build_notices stamps every notice with raw_html_supported — without
      # that, notice_message/2's unknown_placeholder wording could not tell
      # the "convert it now" case from the "do not, it's a trap" one.
      # Hardcoding this field to true would still pass every other test.
      plan =
        TemplateExport.plan([invoice("{{mystery_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: false
        )

      assert [%{kind: :unknown_placeholder, raw_html_supported: false}] = plan.notices
    end

    test "reports several unrecognized placeholders in one notice, not one per variable" do
      plan =
        TemplateExport.plan([invoice("{{foo_html}} {{bar_html}}")], invoice_shipped(),
          out: "out",
          raw_html_supported: true
        )

      assert [%{kind: :unknown_placeholder, names: names}] = plan.notices
      assert Enum.sort(names) == ["bar_html", "foo_html"]
    end

    test "uses the loaded phoenix_kit_templates version when the option is omitted" do
      # Computed via the exact function plan/3 itself falls back to, so this
      # stays correct however that version detection behaves, rather than
      # duplicating its logic (or this repo's current phoenix_kit_templates
      # pin) here. This does NOT exercise default_raw_html_support?/0's own
      # correctness or its Application.load/1 fallback — the application is
      # always already loaded in this test process, so that branch never
      # runs here. See TemplateExportVersionTest for that.
      expected_supported? = TemplateExport.default_raw_html_support?()

      plan = TemplateExport.plan([invoice("{{line_items_html}}")], invoice_shipped(), out: "out")

      if expected_supported? do
        assert html_file(plan) == "{{{line_items_html}}}"
        assert [%{kind: :rewritten}] = plan.notices
      else
        assert html_file(plan) == "{{line_items_html}}"
        assert [%{kind: :needs_manual_rewrite}] = plan.notices
      end
    end

    defp real_seed(name) do
      Templates.default_system_templates()
      |> Enum.find(&(&1.name == name))
      |> Map.take([:name, :subject, :text_body, :html_body])
    end

    test "billing_invoice is rewritten the same way, starting from the real seed" do
      seed = real_seed("billing_invoice")
      edited_html = String.replace(seed.html_body["en"], "{{tax_amount}}", "{{tax_amount}} incl.")
      edited = struct(%Template{is_system: true}, %{seed | html_body: %{"en" => edited_html}})

      plan =
        TemplateExport.plan([edited], Templates.default_system_templates(),
          out: "out",
          raw_html_supported: true
        )

      expected_html = String.replace(edited_html, "{{line_items_html}}", "{{{line_items_html}}}")
      assert file(plan, "billing_invoice/html.html") == expected_html
      assert file(plan, "billing_invoice/subject.txt") == seed.subject["en"]
      assert file(plan, "billing_invoice/text.txt") == seed.text_body["en"]

      assert Enum.any?(
               plan.notices,
               &(&1.kind == :rewritten and String.ends_with?(&1.path, "billing_invoice/html.html"))
             )
    end

    test "billing_receipt is rewritten the same way, starting from the real seed" do
      seed = real_seed("billing_receipt")

      edited_html = String.replace(seed.html_body["en"], "{{paid_amount}}", "{{paid_amount}} USD")

      edited = struct(%Template{is_system: true}, %{seed | html_body: %{"en" => edited_html}})

      plan =
        TemplateExport.plan([edited], Templates.default_system_templates(),
          out: "out",
          raw_html_supported: true
        )

      expected_html = String.replace(edited_html, "{{line_items_html}}", "{{{line_items_html}}}")
      assert file(plan, "billing_receipt/html.html") == expected_html
      assert file(plan, "billing_receipt/subject.txt") == seed.subject["en"]
      assert file(plan, "billing_receipt/text.txt") == seed.text_body["en"]

      assert Enum.any?(
               plan.notices,
               &(&1.kind == :rewritten and String.ends_with?(&1.path, "billing_receipt/html.html"))
             )
    end
  end

  describe "rewrite_raw_html/3" do
    test "rewrites every occurrence of a known variable, as one notice" do
      {content, notices} =
        TemplateExport.rewrite_raw_html(
          "{{line_items_html}}...{{ line_items_html }}",
          "some/path/html.html",
          true
        )

      assert content == "{{{line_items_html}}}...{{{line_items_html}}}"

      assert [%{path: "some/path/html.html", kind: :rewritten, names: ["line_items_html"]}] =
               notices
    end

    test "an unbound unrelated placeholder is left alone" do
      {content, notices} = TemplateExport.rewrite_raw_html("{{total}}", "x.html", true)

      assert content == "{{total}}"
      assert notices == []
    end

    test "a known name is rewritten even without an _html suffix" do
      # Filtering candidates by the _html suffix before checking membership
      # in the known list would silently skip a known name spelled any other
      # way. opts[:known] stands in for a hypothetical raw_html_variables/0
      # entry without that suffix, without actually adding one to the real
      # list.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{raw_markup}}", "x.html", true, known: ["raw_markup"])

      assert content == "{{{raw_markup}}}"
      assert [%{kind: :rewritten, names: ["raw_markup"]}] = notices
    end

    test "is idempotent on a part that mixes the double and triple form of the same name" do
      # See the matching plan/3 test for why this is the case that would catch
      # a naive whole-string `String.replace/3` regression.
      {content, notices} =
        TemplateExport.rewrite_raw_html(
          "{{line_items_html}} {{{line_items_html}}}",
          "x.html",
          true
        )

      assert content == "{{{line_items_html}}} {{{line_items_html}}}"
      assert [%{kind: :rewritten, names: ["line_items_html"]}] = notices
    end

    test "the _html suffix is matched case-insensitively" do
      {content, notices} = TemplateExport.rewrite_raw_html("{{promo_HTML}}", "x.html", true)

      assert content == "{{promo_HTML}}"
      assert [%{kind: :unknown_placeholder, names: ["promo_HTML"]}] = notices
    end

    test "several unknown placeholders in one part produce a single notice" do
      {_content, notices} =
        TemplateExport.rewrite_raw_html("{{foo_html}} {{bar_html}}", "x.html", true)

      assert [%{kind: :unknown_placeholder, names: names}] = notices
      assert Enum.sort(names) == ["bar_html", "foo_html"]
    end

    # Boundary cases from PhoenixKit.Templates.Substitution's own moduledoc —
    # the "obvious" reading of these is wrong, and this module copies that
    # package's placeholder syntax without depending on it, so these pin the
    # copy down independently of that source ever changing underneath it.
    test "an already-quadruple-brace placeholder is recognized as a triple inside literal braces" do
      # {{{{x}}}} parses as literal `{` + the triple-brace placeholder + literal
      # `}` — already raw, so nothing to rewrite.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{{{line_items_html}}}}", "x.html", true)

      assert content == "{{{{line_items_html}}}}"
      assert notices == []
    end

    test "a triple-brace placeholder missing its third closing brace still rewrites the double form underneath" do
      # Only two closing braces exist, so the triple form has nothing to
      # complete; the double form does, one character in, leaving the first
      # `{` as a literal that survives the rewrite untouched.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{{line_items_html}}", "x.html", true)

      assert content == "{{{{line_items_html}}}"
      assert [%{kind: :rewritten, names: ["line_items_html"]}] = notices
    end

    test "a double-brace placeholder with one extra trailing brace rewrites underneath it" do
      # Mirror of the row above: the double form completes as {{x}}; the
      # extra trailing `}` is literal and survives the rewrite untouched.
      {content, notices} =
        TemplateExport.rewrite_raw_html("{{line_items_html}}}", "x.html", true)

      assert content == "{{{line_items_html}}}}"
      assert [%{kind: :rewritten, names: ["line_items_html"]}] = notices
    end

    test "single outer braces are never part of the placeholder" do
      {content, notices} =
        TemplateExport.rewrite_raw_html("{ {{line_items_html}} }", "x.html", true)

      assert content == "{ {{{line_items_html}}} }"
      assert [%{kind: :rewritten, names: ["line_items_html"]}] = notices
    end
  end

  describe "raw_html_support?/1" do
    test "true from 0.2.0 onward, false below it" do
      refute TemplateExport.raw_html_support?("0.1.2")
      assert TemplateExport.raw_html_support?("0.2.0")
      assert TemplateExport.raw_html_support?("0.2.1")
    end

    test "a pre-release of the minimum version does not count as supported" do
      refute TemplateExport.raw_html_support?("0.2.0-rc.1")
    end

    test "a charlist version (as Application.spec/2 returns it) works the same as a string" do
      assert TemplateExport.raw_html_support?(~c"0.2.0")
      refute TemplateExport.raw_html_support?(~c"0.1.2")
    end

    test "nil is unsupported" do
      refute TemplateExport.raw_html_support?(nil)
    end

    test "a value Version cannot parse is unsupported, not an exception" do
      refute TemplateExport.raw_html_support?("not-a-version")
    end
  end

  describe "notice_message/2" do
    test "a rewritten notice reads in the past tense when the file was actually written" do
      notice = %{path: "out/x/html.html", kind: :rewritten, names: ["line_items_html"]}

      assert {:info, message} = TemplateExport.notice_message(notice, :written)
      assert message =~ "rewrote {{line_items_html}} to {{{line_items_html}}}"
    end

    test "a rewritten notice reads as proposed under a dry run" do
      notice = %{path: "out/x/html.html", kind: :rewritten, names: ["line_items_html"]}

      assert {:info, message} = TemplateExport.notice_message(notice, :would_write)
      assert message =~ "would rewrite {{line_items_html}} to {{{line_items_html}}}"
    end

    test "a rewritten notice with no outcome yet reads the same as a dry run, not as already done" do
      # nil is what a caller gets from calling this without ever going through
      # write_files/2 (e.g. rewrite_raw_html/3 directly) — it must not read as
      # a rewrite that has already happened.
      notice = %{path: "out/x/html.html", kind: :rewritten, names: ["line_items_html"]}

      assert {:info, message} = TemplateExport.notice_message(notice, nil)
      assert message =~ "would rewrite {{line_items_html}} to {{{line_items_html}}}"
    end

    test "a rewritten notice becomes a warning that gives no automatic advice when the file was skipped" do
      # Trusts the notice it is given — this is the wording for a skipped file
      # a caller has already confirmed (via reconcile_skipped_notice/2) still
      # needs the rewrite. It must not push the operator toward --force: that
      # flag overwrites every skipped file, including any unrelated manual
      # edits in them, not just this one variable in this one file.
      notice = %{path: "out/x/html.html", kind: :rewritten, names: ["line_items_html"]}

      assert {:warning, message} = TemplateExport.notice_message(notice, :skipped)
      assert message =~ "skipped"
      assert message =~ "edit the file by hand"
      refute message =~ "rewrote"
      refute message =~ "--force"
    end

    test "needs_manual_rewrite is always a warning, regardless of the file's write outcome" do
      notice = %{path: "out/x/html.html", kind: :needs_manual_rewrite, names: ["line_items_html"]}

      for outcome <- [:written, :would_write, :skipped, nil] do
        assert {:warning, message} = TemplateExport.notice_message(notice, outcome)
        assert message =~ "does not support {{{...}}}"
        assert message =~ "replace {{line_items_html}} with {{{line_items_html}}}"

        # Without this clause the advice reads as "do this now" — exactly
        # the reverse-trap case this kind exists to avoid below 0.2.0.
        assert message =~ "after upgrading core to >= 2.40"
      end
    end

    test "unknown_placeholder, raw_html_supported: true, advises fixing it now and listing every name in one line" do
      # The advice must be something the host operator running this task can
      # actually do — editing their own file and pinging the package
      # maintainer — not "edit Template.raw_html_variables/0", which is this
      # library's own source and not theirs to change.
      notice = %{
        path: "out/x/html.html",
        kind: :unknown_placeholder,
        names: ["foo_html", "bar_html"],
        raw_html_supported: true
      }

      assert {:warning, message} = TemplateExport.notice_message(notice, nil)
      assert message =~ "unknown raw-HTML placeholder {{foo_html}}, {{bar_html}}"
      assert message =~ "change it to {{{foo_html}}}, {{{bar_html}}} by hand in this file"
      assert message =~ "maintainer"
      refute message =~ "Template.raw_html_variables/0"
    end

    test "unknown_placeholder, raw_html_supported: false, warns against the triple-brace fix instead of suggesting it" do
      # The reverse-trap case: on a phoenix_kit_templates that does not
      # understand {{{...}}}, writing it there would render as a literal
      # `{V}` with stray braces — actively wrong, not merely premature.
      notice = %{
        path: "out/x/html.html",
        kind: :unknown_placeholder,
        names: ["foo_html"],
        raw_html_supported: false
      }

      assert {:warning, message} = TemplateExport.notice_message(notice, nil)
      assert message =~ "unknown raw-HTML placeholder {{foo_html}}"
      assert message =~ "Do NOT change it to {{{foo_html}}} now"
      assert message =~ "upgraded to >= 2.40"
      refute message =~ "change it to {{{foo_html}}} by hand in this file"
    end

    test "could_not_verify is a warning that says it could not check the file" do
      notice = %{
        path: "out/x/html.html",
        kind: :could_not_verify,
        names: ["line_items_html"],
        raw_html_supported: true
      }

      assert {:warning, message} = TemplateExport.notice_message(notice, :skipped)
      assert message =~ "could not read"
      assert message =~ "out/x/html.html"
    end
  end

  describe "reconcile_skipped_notice/2" do
    @tag :tmp_dir
    test "returns nil once the on-disk file no longer has the problem", %{tmp_dir: dir} do
      path = Path.join(dir, "html.html")
      File.write!(path, "<p>{{{line_items_html}}}</p>")

      notice = %{
        path: path,
        kind: :rewritten,
        names: ["line_items_html"],
        raw_html_supported: false
      }

      assert TemplateExport.reconcile_skipped_notice(notice, false) == nil
    end

    @tag :tmp_dir
    test "still returns a notice when the on-disk file genuinely still needs it", %{tmp_dir: dir} do
      path = Path.join(dir, "html.html")
      File.write!(path, "<p>{{line_items_html}}</p>")

      notice = %{
        path: path,
        kind: :needs_manual_rewrite,
        names: ["line_items_html"],
        raw_html_supported: false
      }

      assert %{kind: :needs_manual_rewrite, names: ["line_items_html"]} =
               TemplateExport.reconcile_skipped_notice(notice, false)
    end

    @tag :tmp_dir
    test "an unknown_placeholder notice clears once the file no longer has that placeholder", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "html.html")
      File.write!(path, "<p>{{{promo_html}}}</p>")

      notice = %{
        path: path,
        kind: :unknown_placeholder,
        names: ["promo_html"],
        raw_html_supported: true
      }

      assert TemplateExport.reconcile_skipped_notice(notice, true) == nil
    end

    @tag :tmp_dir
    test "matches the notice back to its own kind when the file still has both kinds of problem at once",
         %{tmp_dir: dir} do
      # If this matched by taking the first fresh notice found instead of
      # the one whose kind equals the original notice's kind, a file with
      # both problems would get the same message twice — once for each
      # original notice — instead of one message per problem.
      path = Path.join(dir, "html.html")
      File.write!(path, "<p>{{line_items_html}}</p><p>{{mystery_html}}</p>")

      known_notice = %{
        path: path,
        kind: :needs_manual_rewrite,
        names: ["line_items_html"],
        raw_html_supported: false
      }

      unknown_notice = %{
        path: path,
        kind: :unknown_placeholder,
        names: ["mystery_html"],
        raw_html_supported: false
      }

      assert %{kind: :needs_manual_rewrite, names: ["line_items_html"]} =
               TemplateExport.reconcile_skipped_notice(known_notice, false)

      assert %{kind: :unknown_placeholder, names: ["mystery_html"]} =
               TemplateExport.reconcile_skipped_notice(unknown_notice, false)
    end

    test "returns a could_not_verify notice, not the plan-time one, when the file cannot be read" do
      notice = %{
        path: "/nonexistent/path/html.html",
        kind: :rewritten,
        names: ["line_items_html"],
        raw_html_supported: true
      }

      assert %{kind: :could_not_verify, path: "/nonexistent/path/html.html"} =
               TemplateExport.reconcile_skipped_notice(notice, true)
    end
  end

  describe "against the templates this package actually ships" do
    test "a freshly seeded row would export nothing" do
      # The whole point of the classification: an install that never touched a
      # template exports zero files, so the diff an operator reviews contains
      # only their own edits.
      shipped = Templates.default_system_templates()

      rows =
        Enum.map(shipped, fn attrs ->
          struct(
            %Template{is_system: true},
            Map.take(attrs, [:name, :subject, :text_body, :html_body])
          )
        end)

      plan = TemplateExport.plan(rows, shipped)

      assert plan.edited == []
      assert plan.files == []
      assert length(plan.untouched) == length(shipped)
    end
  end

  describe "write_files/2" do
    @tag :tmp_dir
    test "creates the directory tree and writes the content", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])

      assert [{^path, :written}] = TemplateExport.write_files([{path, "Confirm"}])
      assert File.read!(path) == "Confirm"
    end

    @tag :tmp_dir
    test "refuses to overwrite a file a human already wrote", %{tmp_dir: dir} do
      # A re-run, or an export onto a host that already hand-wrote an override,
      # must never silently replace it.
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :skipped}] = TemplateExport.write_files([{path, "from the database"}])
      assert File.read!(path) == "hand-written"
    end

    @tag :tmp_dir
    test "overwrites only when explicitly forced", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :written}] =
               TemplateExport.write_files([{path, "from the database"}], force: true)

      assert File.read!(path) == "from the database"
    end

    @tag :tmp_dir
    test "a dry run touches nothing", %{tmp_dir: dir} do
      path = Path.join([dir, "register", "subject.txt"])

      assert [{^path, :would_write}] =
               TemplateExport.write_files([{path, "Confirm"}], dry_run: true)

      refute File.exists?(path)
    end

    @tag :tmp_dir
    test "a dry run still reports a pre-existing file as skipped", %{tmp_dir: dir} do
      # So --dry-run tells the truth about what a real run would do.
      path = Path.join([dir, "register", "subject.txt"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "hand-written")

      assert [{^path, :skipped}] = TemplateExport.write_files([{path, "x"}], dry_run: true)
    end
  end
end
