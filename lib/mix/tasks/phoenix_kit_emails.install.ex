defmodule Mix.Tasks.PhoenixKitEmails.Install do
  @moduledoc """
  Installs PhoenixKit Emails module into parent application.

  ## Usage

      mix phoenix_kit_emails.install

  ## What it does

  1. Adds `emails: 50` Oban queue for email processing
  2. Adds `sqs_polling: 1` Oban queue for AWS SQS event polling
  3. Prints next steps for AWS SES configuration
  """

  use Mix.Task

  @shortdoc "Install PhoenixKit Emails module"

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("Installing PhoenixKit Emails...")

    Mix.shell().info("""

    PhoenixKit Emails installed successfully!

    Next steps:
    1. Add {:phoenix_kit_emails, "~> 0.1"} to your mix.exs deps
    2. Run `mix deps.get`
    3. Add Oban queues to config/config.exs:
       - emails: 50
       - sqs_polling: 1
    4. Configure AWS SES credentials in Settings UI or config/prod.exs
    5. Run `mix phoenix_kit.update` to apply email migrations
    6. Enable the Emails module in Admin → Modules
    """)
  end
end
