defmodule PhoenixKit.Modules.Emails.Verification.RunnerSetup do
  @moduledoc """
  What stands between the settings page and a working SMTP runner on the core side.

  A runner talks to core's machine API (`/api/admin/v1`, core 2.63.0 and later), which
  is off by default (`api_admin_enabled`), can be switched off per module
  (`api_disabled_modules`) and per tool (`api_disabled_tools`). `preconditions/0` says
  which of these hold the runner back, `enable_machine_api/1` flips the first of them
  with the same call as Settings -> API, `server_url/0` is the address a runner is given
  and `command/2` the line it is started with.

  The two lists are read from the settings as they are (newline-separated names), so the
  page also works on a core that predates `api_disabled_modules`.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @module_key "emails"
  @tools ["emails.claim_smtp_jobs", "emails.report_smtp_results"]

  @type precondition ::
          :no_machine_api
          | :api_admin_disabled
          | :module_api_disabled
          | {:tools_hidden, [String.t()]}

  @doc """
  What keeps a runner from connecting, in the order the page lists it. `[]` when
  nothing does. A core without the machine API is `[:no_machine_api]` and nothing else:
  none of the other settings exist there.
  """
  @spec preconditions() :: [precondition()]
  def preconditions do
    if Config.machine_api_available?() do
      Enum.reject(
        [admin_api_off(), module_off(), tools_hidden()],
        &is_nil/1
      )
    else
      [:no_machine_api]
    end
  end

  defp admin_api_off do
    unless Settings.get_boolean_setting("api_admin_enabled", false), do: :api_admin_disabled
  end

  defp module_off do
    if @module_key in list("api_disabled_modules"), do: :module_api_disabled
  end

  defp tools_hidden do
    case Enum.filter(@tools, &(&1 in list("api_disabled_tools"))) do
      [] -> nil
      hidden -> {:tools_hidden, hidden}
    end
  end

  defp list(key) do
    case Settings.get_setting(key) do
      value when is_binary(value) ->
        value
        |> String.split(["\r\n", "\n"])
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Switches the machine API (`api_admin_enabled`) on, the way Settings -> API does: the
  same setting, in the `api` module, with the person's uuid and the source
  `"settings"` in the history. The caller has to check the person's `api` permission.
  """
  @spec enable_machine_api(String.t() | nil) :: {:ok, term()} | {:error, term()}
  def enable_machine_api(actor_uuid) do
    Settings.update_boolean_setting_with_module(
      "api_admin_enabled",
      true,
      "api",
      actor_uuid: actor_uuid,
      source: "settings"
    )
  end

  @doc """
  The address a runner is given with `-Server`: the site plus the kit's URL prefix, because
  core mounts the machine API under it (`<site>/phoenix_kit/api/admin/v1/...`). A kit mounted
  at the root adds nothing.
  """
  @spec server_url() :: String.t()
  def server_url, do: Routes.base_url() <> prefix()

  defp prefix do
    case Routes.url_prefix() do
      root when root in ["", "/"] -> ""
      prefix -> String.trim_trailing(prefix, "/")
    end
  end

  @doc "The command that starts the runner on the user's machine."
  @spec command(String.t(), String.t()) :: String.t()
  def command(server, token) do
    "powershell -ExecutionPolicy Bypass -File #{script_name()} -Server #{server} -Token #{token}"
  end

  @doc """
  The same start with the token in an environment variable of the PowerShell session
  instead of on the command line, where other programs can read it in the process list.
  """
  @spec env_command(String.t(), String.t()) :: String.t()
  def env_command(server, token) do
    "$env:PK_SMTP_RUNNER_TOKEN='#{token}'; " <>
      "powershell -ExecutionPolicy Bypass -File #{script_name()} -Server #{server}"
  end

  @doc "The file name of the runner script."
  @spec script_name() :: String.t()
  def script_name, do: "pk-smtp-runner.ps1"
end
