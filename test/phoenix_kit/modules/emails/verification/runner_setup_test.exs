defmodule PhoenixKit.Modules.Emails.Verification.RunnerSetupTest do
  @moduledoc """
  What must hold on the core side before a runner can connect (the machine API is on,
  the module's API is not switched off, its tools are not hidden), the switch that turns
  the machine API on, and the command a runner is started with.
  """

  # Not async: the settings it flips are read by the named API processes.
  use PhoenixKitEmails.DataCase, async: false

  import PhoenixKitEmails.Test.ApiHarness, only: [put_setting: 2, setup_api: 0, user_with: 1]

  alias PhoenixKit.Modules.Emails.Verification.RunnerSetup
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Utils.Routes

  setup do
    setup_api()
    :ok
  end

  describe "preconditions/0" do
    test "none when the machine API is on and the tools are visible" do
      assert RunnerSetup.preconditions() == []
    end

    test "the admin API is off by default in core" do
      put_setting("api_admin_enabled", "false")

      assert RunnerSetup.preconditions() == [:api_admin_disabled]
    end

    test "the module listed in api_disabled_modules" do
      put_setting("api_disabled_modules", "newsletters\nemails")

      assert RunnerSetup.preconditions() == [:module_api_disabled]
    end

    test "a hidden tool is named" do
      put_setting("api_disabled_tools", "emails.report_smtp_results\ncatalogue.products_list")

      assert RunnerSetup.preconditions() == [{:tools_hidden, ["emails.report_smtp_results"]}]
    end

    test "all of them at once, in the order the page lists them" do
      put_setting("api_admin_enabled", "false")
      put_setting("api_disabled_modules", "emails")
      put_setting("api_disabled_tools", "emails.claim_smtp_jobs\nemails.report_smtp_results")

      assert RunnerSetup.preconditions() ==
               [
                 :api_admin_disabled,
                 :module_api_disabled,
                 {:tools_hidden, ["emails.claim_smtp_jobs", "emails.report_smtp_results"]}
               ]
    end

    test "a core without the machine API has nothing else to check" do
      Application.put_env(:phoenix_kit_emails, :verification_machine_api, false)
      on_exit(fn -> Application.delete_env(:phoenix_kit_emails, :verification_machine_api) end)

      put_setting("api_admin_enabled", "false")

      assert RunnerSetup.preconditions() == [:no_machine_api]
    end
  end

  describe "enable_machine_api/1" do
    test "switches the admin API on through the setting core's own page writes" do
      put_setting("api_admin_enabled", "false")

      assert {:ok, _setting} = RunnerSetup.enable_machine_api(nil)

      assert Settings.get_boolean_setting("api_admin_enabled", false)
      assert RunnerSetup.preconditions() == []
    end

    test "keeps the setting in the api module, as the API page does" do
      put_setting("api_admin_enabled", "false")
      {:ok, _} = RunnerSetup.enable_machine_api(nil)

      assert %{module: "api"} =
               Queries.get_setting_by_key("api_admin_enabled")
    end

    test "records who did it" do
      put_setting("api_admin_enabled", "false")
      {user, _role} = user_with(["api"])

      {:ok, _} = RunnerSetup.enable_machine_api(user.uuid)

      assert [latest | _] = History.list("api_admin_enabled")
      assert latest.actor_uuid == user.uuid
    end
  end

  describe "server_url/0" do
    setup do
      previous = Application.get_env(:phoenix_kit, :url_prefix)
      PhoenixKit.Config.clear_url_prefix_cache()

      on_exit(fn ->
        if is_nil(previous),
          do: Application.delete_env(:phoenix_kit, :url_prefix),
          else: Application.put_env(:phoenix_kit, :url_prefix, previous)

        PhoenixKit.Config.clear_url_prefix_cache()
      end)

      :ok
    end

    defp with_prefix(prefix) do
      Application.put_env(:phoenix_kit, :url_prefix, prefix)
      PhoenixKit.Config.clear_url_prefix_cache()
    end

    test "carries the kit's URL prefix: the machine API lives under it" do
      with_prefix("/phoenix_kit")
      assert RunnerSetup.server_url() == Routes.base_url() <> "/phoenix_kit"
    end

    test "a prefix with a trailing slash has none in the address" do
      with_prefix("/admin-kit/")
      assert RunnerSetup.server_url() == Routes.base_url() <> "/admin-kit"
    end

    test "a kit mounted at the root adds nothing" do
      with_prefix("/")
      assert RunnerSetup.server_url() == Routes.base_url()

      with_prefix("")
      assert RunnerSetup.server_url() == Routes.base_url()
    end
  end

  describe "command/2" do
    test "is the line of the instruction with the site and the token filled in" do
      assert RunnerSetup.command("https://acme-mail.test", "pk_ab12cd34_secret") ==
               "powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 " <>
                 "-Server https://acme-mail.test -Token pk_ab12cd34_secret"
    end
  end

  describe "env_command/2" do
    test "puts the token in the environment variable and leaves -Token out" do
      command = RunnerSetup.env_command("https://acme-mail.test", "pk_ab12cd34_secret")

      assert command ==
               "$env:PK_SMTP_RUNNER_TOKEN='pk_ab12cd34_secret'; " <>
                 "powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 " <>
                 "-Server https://acme-mail.test"

      refute command =~ "-Token"
    end
  end
end
