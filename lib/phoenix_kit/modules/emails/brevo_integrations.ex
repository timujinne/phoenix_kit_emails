defmodule PhoenixKit.Modules.Emails.BrevoIntegrations do
  @moduledoc """
  Shared "which Brevo account(s) are actually active" resolution, used by
  everything that needs to reach the Brevo events API on behalf of the
  currently-configured sender(s): `BrevoPollingJob` (the background
  poll), `BrevoOnDemandSync` (the "sync now" button), and the "Brevo
  Events" settings section's per-account opt-out list.

  "Active" means an *enabled* `PhoenixKit.Email.SendProfile` pointed at
  a `"brevo_api"` integration — the same sender-aware definition
  `BrevoPollingJob`'s moduledoc documents.
  """

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations

  @doc """
  Every distinct `integration_uuid` referenced by an enabled `brevo_api`
  SendProfile. Multiple profiles can share one integration/API key —
  deduplicated so callers don't fetch the same account twice.
  """
  @spec active_integration_uuids() :: [String.t()]
  def active_integration_uuids do
    SendProfiles.list_send_profiles()
    |> Enum.filter(&active_brevo_profile?/1)
    |> Enum.map(& &1.integration_uuid)
    |> Enum.uniq()
  end

  defp active_brevo_profile?(%SendProfile{
         enabled: true,
         provider_kind: "brevo_api",
         integration_uuid: uuid
       }),
       do: is_binary(uuid) and uuid != ""

  defp active_brevo_profile?(_profile), do: false

  @doc """
  Resolves the decrypted `api_key` for a Brevo integration.
  """
  @spec resolve_api_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_api_key(integration_uuid) do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, %{"api_key" => api_key}} when is_binary(api_key) and api_key != "" ->
        {:ok, api_key}

      {:ok, _creds} ->
        {:error, :missing_api_key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  `{integration_uuid, name}` pairs for every account
  `active_integration_uuids/0` would poll — for the settings UI's
  per-account opt-out list, which needs a human-readable name alongside
  the uuid it writes to the exclusion setting.
  """
  @spec active_integrations_with_names() :: [{String.t(), String.t()}]
  def active_integrations_with_names do
    active_integration_uuids()
    |> Enum.map(fn uuid ->
      case Integrations.get_integration_by_uuid(uuid) do
        {:ok, %{name: name}} -> {uuid, name}
        _ -> {uuid, uuid}
      end
    end)
  end
end
