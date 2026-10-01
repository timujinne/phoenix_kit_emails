defmodule Mix.Tasks.PhoenixKitEmails.Templates.Export do
  @shortdoc "Export customized email templates to override files"

  @moduledoc """
  Carries operator-edited email templates out of the database and into files.

  Message templates are moving from `phoenix_kit_email_templates` to files a
  host owns in its own repository, where they are version-controlled and
  reviewable. This task is the upgrade path: it writes every row an operator
  actually edited into the layout core reads, so those edits survive the table
  being retired.

      mix phoenix_kit_emails.templates.export

  Run it, review the diff, commit the files. Nothing is deleted and no database
  row is touched — the database layer still wins at send time until the table
  is dropped in a later release, so an export that turns out wrong costs
  nothing but the files.

  ## What gets exported

  Only system templates an operator actually edited. Untouched ones are
  skipped (core supplies those itself now, translated into every shipped
  locale), and operator-authored rows are left alone — those are newsletter
  layouts, and they keep a table and an editor.

  `PhoenixKit.Modules.Emails.TemplateExport` decides all of this and documents
  why, including the locale rule that governs the filenames.

  ## Raw-HTML variables

  A variable whose value is already-rendered HTML — so far only
  `line_items_html`, billing's ready-rendered line-items table — needs
  different handling than plain text. From `phoenix_kit_templates` 0.2.0
  onward the `html` part escapes `{{var}}` values, so a variable like that
  must be written as `{{{var}}}` (triple braces) instead. This task rewrites
  such names automatically when the loaded `phoenix_kit_templates` is 0.2.0
  or newer, and prints which files it touched. On an older
  `phoenix_kit_templates`, the file is written unchanged and a warning
  explains it needs that manual edit once core is upgraded to `>= 2.40` (see
  `PhoenixKit.Modules.Emails.TemplateExport`).

  ## Options

    * `--dry-run` — report what would be written, write nothing.
    * `--force` — overwrite existing files. Refused by default, so a
      hand-written override is never clobbered by a re-run.
    * `--out DIR` — target directory (default `priv/phoenix_kit_templates`).
  """

  use Mix.Task

  alias PhoenixKit.Modules.Emails.TemplateExport
  alias PhoenixKit.Modules.Emails.Templates

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [dry_run: :boolean, force: :boolean, out: :string])

    Mix.Task.run("app.start")

    out = Keyword.get(opts, :out, "priv/phoenix_kit_templates")
    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)

    plan = TemplateExport.plan(load_templates(), Templates.default_system_templates(), out: out)

    written = TemplateExport.write_files(plan.files, dry_run: dry_run?, force: force?)

    report(plan, written, out)
  end

  # An operator runs this once, during an upgrade, and a raw Ecto stacktrace
  # is a poor way to learn the task was run from the wrong directory. A dead
  # pool exits rather than raising, so both are caught.
  defp load_templates do
    Templates.list_templates()
  rescue
    error -> database_unreachable!(Exception.message(error))
  catch
    :exit, reason -> database_unreachable!(inspect(reason))
  end

  @spec database_unreachable!(String.t()) :: no_return()
  defp database_unreachable!(detail) do
    Mix.raise("""
    Could not read email templates from the database.

    Run this from your host application, where the PhoenixKit repo is
    configured and started:

        cd /path/to/your_app
        mix phoenix_kit_emails.templates.export

    (#{detail})
    """)
  end

  defp report(plan, written, out) do
    shell = Mix.shell()

    if plan.edited == [] do
      shell.info([
        :green,
        "Nothing to export",
        :reset,
        " — no system template differs from what this package ships."
      ])
    else
      shell.info([
        :bright,
        "Exporting #{length(plan.edited)} edited template(s) to #{out}/",
        :reset
      ])
    end

    for {path, outcome} <- written do
      case outcome do
        :skipped ->
          shell.info([
            :yellow,
            "  skip   ",
            :reset,
            path,
            " (exists — pass --force to overwrite)"
          ])

        :would_write ->
          shell.info(["  would write ", path])

        :written ->
          shell.info(["  wrote  ", path])
      end
    end

    outcome_by_path = Map.new(written)

    for notice <- plan.notices do
      outcome = Map.get(outcome_by_path, notice.path)
      reconciled = reconcile(notice, outcome, plan.raw_html_supported)

      if reconciled do
        {level, message} = TemplateExport.notice_message(reconciled, outcome)

        case level do
          :warning -> shell.info([:yellow, "  warn   ", :reset, message])
          :info -> shell.info([:cyan, "  note   ", :reset, message])
        end
      end
    end

    note(shell, plan.untouched, "untouched system template(s)", [
      "core supplies these itself now, translated into every shipped locale"
    ])

    note(shell, plan.authored, "operator-authored template(s)", [
      "these are not system templates and do not become files; ",
      "they move to phoenix_kit_newsletters"
    ])
  end

  # A skipped file was left untouched this run, so the notice `plan/3` built
  # from the *database* content describes what this run would have written,
  # not the file it actually left alone. Reconciling against the real file
  # is what keeps a second run without `--force` from repeating a warning
  # about something a previous run — or an operator's own edit — already
  # fixed.
  defp reconcile(notice, :skipped, raw_html_supported?) do
    TemplateExport.reconcile_skipped_notice(notice, raw_html_supported?)
  end

  defp reconcile(notice, _outcome, _raw_html_supported?), do: notice

  defp note(_shell, [], _label, _why), do: :ok

  defp note(shell, templates, label, why) do
    shell.info([
      :faint,
      "\n#{length(templates)} #{label} left alone — ",
      why,
      ": ",
      Enum.map_join(templates, ", ", & &1.name),
      :reset
    ])
  end
end
