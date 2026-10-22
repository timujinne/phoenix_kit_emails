defmodule Mix.Tasks.PhoenixKitEmails.Install do
  @moduledoc """
  Installs PhoenixKit Emails module into parent application.

  Adds the required `@source` directive to your CSS file so Tailwind CSS
  can discover classes used by the emails module's templates.

  ## Usage

      mix phoenix_kit_emails.install

  ## What it does

  1. Finds your `assets/css/app.css` file
  2. Adds `@source "../../deps/phoenix_kit_emails";` after existing `@source` lines
  3. Prints next steps for AWS SES configuration

  This task is idempotent — safe to run multiple times.
  """

  use Mix.Task

  @shortdoc "Install PhoenixKit Emails module"

  @source_directive ~s(@source "../../deps/phoenix_kit_emails";)
  @source_pattern ~r/@source\s+["'][^"']*phoenix_kit_emails["']/

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("Installing PhoenixKit Emails...")

    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    case find_app_css(css_paths) do
      {:ok, css_path} ->
        add_css_source(css_path)

      {:error, :not_found} ->
        print_manual_css_instructions()
    end

    print_next_steps()
  end

  defp find_app_css(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp add_css_source(css_path) do
    content = File.read!(css_path)

    if String.match?(content, @source_pattern) do
      Mix.shell().info("  ✓ CSS source already configured in #{css_path}")
    else
      updated = insert_source_directive(content)
      File.write!(css_path, updated)
      Mix.shell().info("  ✓ Added @source directive to #{css_path}")
    end
  end

  defp insert_source_directive(content) do
    lines = String.split(content, "\n")

    last_source_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {line, _index} ->
        String.match?(line, ~r/^@source\s+/)
      end)

    case last_source_index do
      {_line, index} ->
        {before, after_lines} = Enum.split(lines, index + 1)
        Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

      nil ->
        import_index =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, _} -> String.match?(line, ~r/^@import\s+/) end)

        case import_index do
          {_line, index} ->
            {before, after_lines} = Enum.split(lines, index + 1)
            Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

          nil ->
            @source_directive <> "\n" <> content
        end
    end
  end

  defp print_manual_css_instructions do
    Mix.shell().info("""

      ⚠  Could not find app.css. Please manually add this line:

         #{@source_directive}

      Common locations: assets/css/app.css
    """)
  end

  defp print_next_steps do
    Mix.shell().info("""

    PhoenixKit Emails installed successfully!

    Next steps:
    1. Run `mix deps.get` if you haven't already
    2. Add Oban queues AND the reconcile Cron entry to config/config.exs —
       ALL queues below are required (not just emails/sqs_polling):
       one per event-tracker chain (sqs_polling, brevo_polling), plus
       event_tracker_reconcile for the tracker-lifecycle correctness
       backbone (see PhoenixKit.Modules.Emails.EventTrackerReconcileWorker's
       moduledoc — without this queue+crontab entry, a tracker whose chain
       dies or was never started is never resurrected until the next app
       restart, only masked by the one-time boot reconcile):

         config :your_app, Oban,
           queues: [
             emails: 50,
             sqs_polling: 1,
             brevo_polling: 1,
             event_tracker_reconcile: 1,
             email_archival: 1,
             email_verification: 5
           ],
           plugins: [
             Oban.Plugins.Pruner,
             Oban.Plugins.Lifeline,
             {Oban.Plugins.Cron,
              crontab: [
                {"*/2 * * * *", PhoenixKit.Modules.Emails.EventTrackerReconcileWorker},
                {"0 * * * *", PhoenixKit.Modules.Emails.ArchiveWorker}
              ]}
           ]

       The `email_verification` queue runs the e-mail address verification
       batches (`Verification.start_batch/4`); without it those jobs are
       stored and never run. Its limit is how many addresses one node checks
       at once.

       The `email_archival` entry is what gives S3 archival a schedule.
       Without it the feature is inert no matter what the settings page
       says — the archiver is only ever called from that Cron tick.

       MERGE that `plugins:` list into whatever you already have rather
       than replacing it. Lifeline is not optional here: a poller job left
       orphaned in :executing by a node that died mid-cycle blocks the
       reconciler from ever inserting a successor, and the admin panel
       keeps calling that tracker "Active" while it polls nothing.

    3. Configure AWS SES and/or Brevo credentials in Settings UI or
       config/prod.exs
    4. Run `mix phoenix_kit.update` to apply email migrations
    5. Enable the Emails module in Admin → Modules
    """)
  end
end
