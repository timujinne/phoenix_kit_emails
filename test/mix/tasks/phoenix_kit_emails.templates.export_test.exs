defmodule Mix.Tasks.PhoenixKitEmails.Templates.ExportTest do
  @moduledoc """
  The task end to end: what it actually prints and writes, against a real
  database row — the layer none of `TemplateExport`'s own unit tests can
  reach, since `notice_message/2` and `reconcile_skipped_notice/2` only do
  their job when the task actually wires the real write outcome and the real
  on-disk file back into them.

  Several tests here patch `phoenix_kit_templates`'s own loaded version (via
  `PhoenixKitEmails.TestSupport.PhoenixKitTemplatesVersion`) to exercise both
  the "supports triple braces" and "does not" paths deterministically,
  instead of only whichever one this repo's own `mix.lock` happens to pin —
  that pin already has its own dedicated coverage in
  `TemplateExportVersionTest`.
  """
  use PhoenixKitEmails.DataCase, async: false

  alias Mix.Tasks.PhoenixKitEmails.Templates.Export
  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates
  alias PhoenixKitEmails.TestSupport.PhoenixKitTemplatesVersion, as: Version

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)
    :ok
  end

  defp shell_messages do
    receive do
      {:mix_shell, :info, [msg]} -> [msg | shell_messages()]
    after
      0 -> []
    end
  end

  defp warn_lines(output) do
    output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "  warn   "))
  end

  # A warn line is "  warn   #{path}: #{message}" — path is this run's own
  # tmp_dir, which ExUnit derives from the *test's own title*. Checking for
  # "--force" against the whole line is a trap: a title that itself mentions
  # "--force" (to describe what the test is about) sanitizes into a tmp_dir
  # name containing "-force-", making the assertion pass or fail on the path
  # rather than on the actual advice text.
  defp warn_message(line) do
    case String.split(line, "html.html: ", parts: 2) do
      [_path, message] -> message
      [line] -> line
    end
  end

  defp edit_invoice_html(replacement_suffix) do
    {:ok, _} = Templates.seed_system_templates()
    template = Templates.get_template_by_name("billing_invoice")
    html = template.html_body["en"] <> replacement_suffix
    {:ok, _} = Templates.update_template(template, %{html_body: %{"en" => html}})
  end

  @tag :tmp_dir
  test "a dry run reports without writing anything", %{tmp_dir: dir} do
    edit_invoice_html("<!-- edited -->")

    Export.run(["--html", "document", "--out", dir, "--dry-run"])
    output = shell_messages() |> Enum.join("\n")

    refute File.exists?(Path.join([dir, "billing_invoice", "html.html"]))
    assert output =~ "would write"
    assert output =~ "billing_invoice/html.html"
  end

  @tag :tmp_dir
  test "a real run under an old phoenix_kit_templates writes the file unchanged and warns", %{
    tmp_dir: dir
  } do
    edit_invoice_html("<!-- edited -->")

    Version.with_version("0.1.2", fn -> Export.run(["--html", "document", "--out", dir]) end)
    output = shell_messages() |> Enum.join("\n")

    assert File.read!(Path.join([dir, "billing_invoice", "html.html"])) =~ "{{line_items_html}}"
    assert output =~ "  warn   "
    assert output =~ "does not support {{{...}}}"
    refute output =~ "  note   "
  end

  @tag :tmp_dir
  test "a real run under a current phoenix_kit_templates rewrites the file and reports an info note",
       %{tmp_dir: dir} do
    edit_invoice_html("<!-- edited -->")

    Version.with_version("0.2.0", fn -> Export.run(["--html", "document", "--out", dir]) end)
    output = shell_messages() |> Enum.join("\n")

    assert File.read!(Path.join([dir, "billing_invoice", "html.html"])) =~
             "{{{line_items_html}}}"

    assert output =~ "  note   "
    assert output =~ "rewrote {{line_items_html}} to {{{line_items_html}}}"
    refute output =~ "  warn   "
  end

  @tag :tmp_dir
  test "a second run without force skips the file and does not repeat a warning the file no longer needs",
       %{tmp_dir: dir} do
    edit_invoice_html("<!-- edited -->")

    path = Path.join([dir, "billing_invoice", "html.html"])
    File.mkdir_p!(Path.dirname(path))
    # Simulate the file already being fixed by hand (or by a prior export
    # under a newer phoenix_kit_templates) before this run, regardless of
    # what this run's own auto-detected raw_html_supported? would decide.
    File.write!(path, "<p>{{{line_items_html}}}</p>")

    Export.run(["--html", "document", "--out", dir])
    output = shell_messages() |> Enum.join("\n")

    assert File.read!(path) == "<p>{{{line_items_html}}}</p>"
    assert output =~ "  skip   "
    refute output =~ "billing_invoice/html.html: "
  end

  @tag :tmp_dir
  test "a second run without force still warns when the on-disk file genuinely still needs the fix, without recommending the force flag",
       %{tmp_dir: dir} do
    edit_invoice_html("<!-- edited -->")

    path = Path.join([dir, "billing_invoice", "html.html"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "<p>{{line_items_html}}</p>")

    Export.run(["--html", "document", "--out", dir])
    output = shell_messages() |> Enum.join("\n")
    warns = warn_lines(output)

    assert output =~ "  skip   "
    assert warns != []
    refute Enum.any?(warns, &(&1 |> warn_message() |> String.contains?("--force")))
  end

  @tag :tmp_dir
  test "the full lifecycle under a phoenix_kit_templates that supports triple braces: dry run, write, silent repeat, manual revert, and the force flag",
       %{tmp_dir: dir} do
    edit_invoice_html("<!-- edited -->")
    path = Path.join([dir, "billing_invoice", "html.html"])

    Version.with_version("0.2.0", fn ->
      # 1. A dry run proposes the rewrite without writing it.
      Export.run(["--html", "document", "--out", dir, "--dry-run"])
      dry_output = shell_messages() |> Enum.join("\n")
      refute File.exists?(path)
      assert dry_output =~ "would rewrite {{line_items_html}} to {{{line_items_html}}}"

      # 2. A real run writes it, reported as an info note, not a warning.
      Export.run(["--html", "document", "--out", dir])
      write_output = shell_messages() |> Enum.join("\n")
      assert File.read!(path) =~ "{{{line_items_html}}}"
      assert write_output =~ "  note   "
      assert write_output =~ "rewrote {{line_items_html}} to {{{line_items_html}}}"
      refute write_output =~ "  warn   "

      # 3. A second run without the force flag skips the file and stays
      #    silent — it is already correct, so nothing needs saying again.
      Export.run(["--html", "document", "--out", dir])
      repeat_output = shell_messages() |> Enum.join("\n")
      assert repeat_output =~ "  skip   "
      refute repeat_output =~ "billing_invoice/html.html: "

      # 4. An operator manually reverts the file to double braces; the next
      #    run without the force flag must warn again, not stay silent — and
      #    must not push the flag as the fix, since it overwrites every
      #    skipped file, not just this one.
      File.write!(path, "<p>{{line_items_html}}</p>")
      Export.run(["--html", "document", "--out", dir])
      reverted_output = shell_messages() |> Enum.join("\n")
      reverted_warns = warn_lines(reverted_output)
      assert reverted_warns != []
      assert Enum.any?(reverted_warns, &(&1 =~ "edit the file by hand"))
      refute Enum.any?(reverted_warns, &(&1 |> warn_message() |> String.contains?("--force")))

      # 5. The force flag overwrites it with the correct rewrite again.
      Export.run(["--html", "document", "--out", dir, "--force"])
      forced_output = shell_messages() |> Enum.join("\n")
      assert File.read!(path) =~ "{{{line_items_html}}}"
      assert forced_output =~ "rewrote {{line_items_html}} to {{{line_items_html}}}"
    end)
  end

  describe "--html" do
    # A seeded invoice whose edit is a changed greeting, so the row counts as
    # edited and its document and body forms are both on offer.
    defp edit_invoice_title do
      {:ok, _} = Templates.seed_system_templates()
      template = Templates.get_template_by_name("billing_invoice")
      html = String.replace(template.html_body["en"], "Bill To", "Invoiced to")
      {:ok, _} = Templates.update_template(template, %{html_body: %{"en" => html}})
    end

    @tag :tmp_dir
    test "body writes the fragment: no document chrome, the edit kept, the injected-rows caveat reported",
         %{tmp_dir: dir} do
      edit_invoice_title()

      Version.with_version("0.2.0", fn ->
        Export.run(["--html", "body", "--out", dir])
      end)

      output = shell_messages() |> Enum.join("\n")
      written = File.read!(Path.join([dir, "billing_invoice", "html.html"]))

      refute written =~ "<html"
      refute written =~ "<style"
      assert written =~ "Invoiced to"
      assert written =~ "{{{line_items_html}}}"
      assert output =~ "(html: body)"
      assert output =~ "inserts markup that was styled by classes"
    end

    @tag :tmp_dir
    test "document writes the stored document as it is", %{tmp_dir: dir} do
      edit_invoice_title()

      Export.run(["--html", "document", "--out", dir])

      written = File.read!(Path.join([dir, "billing_invoice", "html.html"]))
      assert written =~ "<!DOCTYPE html>"
      assert written =~ "<style>"
      assert shell_messages() |> Enum.join("\n") =~ "(html: document)"
    end

    @tag :tmp_dir
    test "auto follows whether the loaded core has the email layout", %{tmp_dir: dir} do
      edit_invoice_title()

      Export.run(["--out", dir])

      written = File.read!(Path.join([dir, "billing_invoice", "html.html"]))
      mode = TemplateExport.default_html_mode()

      if mode == :body,
        do: refute(written =~ "<html"),
        else: assert(written =~ "<html")
    end

    @tag :tmp_dir
    test "a body export that skips an existing whole-document file says core will not wrap it",
         %{tmp_dir: dir} do
      edit_invoice_title()
      path = Path.join([dir, "billing_invoice", "html.html"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "<!DOCTYPE html><html><body><p>old</p></body></html>")

      Export.run(["--html", "body", "--out", dir])
      output = shell_messages() |> Enum.join("\n")

      assert output =~ "  skip   "
      assert output =~ "whole HTML document"
      assert File.read!(path) =~ "<p>old</p>"
    end

    @tag :tmp_dir
    test "a dry run speaks of what it would do, a real run of what it did", %{tmp_dir: dir} do
      {:ok, _} = Templates.seed_system_templates()
      template = Templates.get_template_by_name("register")

      html =
        String.replace(
          template.html_body["en"],
          ~r/<div class="footer">.*?<\/div>/s,
          ~s(<div class="footer"><p>Acme, Tallinn</p></div>)
        )

      {:ok, _} = Templates.update_template(template, %{html_body: %{"en" => html}})

      Export.run(["--html", "body", "--out", dir, "--dry-run"])
      dry = shell_messages() |> Enum.join("\n")
      refute File.exists?(Path.join([dir, "register", "html.html"]))
      assert dry =~ "would remove as decoration — footer: Acme, Tallinn"
      assert dry =~ "own `_layout`"

      Export.run(["--html", "body", "--out", dir])
      real = shell_messages() |> Enum.join("\n")
      assert real =~ "removed as decoration — footer: Acme, Tallinn"
      refute real =~ "would remove"
    end

    test "an unknown mode is refused" do
      assert_raise Mix.Error, ~r/--html must be body, document or auto/, fn ->
        Export.run(["--html", "fragment"])
      end
    end
  end
end
