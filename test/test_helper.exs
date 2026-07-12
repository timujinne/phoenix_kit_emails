require Logger

# Start the embedded test repo and bring it to the current PhoenixKit
# schema version, so tests exercising Settings/Integrations (e.g. B2/B4
# AWS SES credential resolution) have a real DB to round-trip against.
# Mirrors core phoenix_kit's test_helper.exs db_check; tests tagged
# :integration are excluded when no test DB is reachable.
repo_available =
  try do
    {:ok, _} = PhoenixKitEmails.Test.Repo.start_link()
    PhoenixKit.Migration.ensure_current(PhoenixKitEmails.Test.Repo, log: false)
    Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitEmails.Test.Repo, :manual)
    true
  rescue
    e ->
      IO.puts("""
      \n⚠  Could not connect to test database — integration tests will be excluded.
         Run `createdb phoenix_kit_emails_test` to create it.
         Error: #{Exception.message(e)}
      """)

      false
  catch
    :exit, reason ->
      IO.puts("""
      \n⚠  Could not connect to test database — integration tests will be excluded.
         Run `createdb phoenix_kit_emails_test` to create it.
         Error: #{inspect(reason)}
      """)

      false
  end

exclude = if repo_available, do: [], else: [:integration]

if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
  ExUnit.start(exclude: exclude)
else
  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )

  ExUnit.start(exclude: [:requires_phoenix_kit_i18n_api | exclude])
end
