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

    note(shell, plan.untouched, "untouched system template(s)", [
      "core supplies these itself now, translated into every shipped locale"
    ])

    note(shell, plan.authored, "operator-authored template(s)", [
      "these are not system templates and do not become files; ",
      "they move to phoenix_kit_newsletters"
    ])
  end

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
