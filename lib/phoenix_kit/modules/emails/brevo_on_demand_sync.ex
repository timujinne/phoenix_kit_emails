defmodule PhoenixKit.Modules.Emails.BrevoOnDemandSync do
  @moduledoc """
  On-demand, targeted Brevo event fetch for a single email log — the
  Brevo-aware branch of the "sync status now" button (Details page and
  the emails list row menu both call it). Unlike `BrevoPollingJob`'s
  broad polling cycle, this queries Brevo's events API filtered to
  exactly one `messageId` — the cheapest, most precise request the API
  supports.

  A manual, explicit user request: bypasses `brevo_events_enabled` (the
  background poller can be off entirely and this still works) and the
  per-integration opt-out list (excluding an account from the
  *background* poll doesn't mean "never fetch its data even when asked
  directly"). Does NOT bypass `Emails.enabled?/0` — the whole email
  system being off is a stronger signal than either of those.

  There's no per-log integration reference to resolve credentials from
  (a `Log` doesn't record which `SendProfile`/integration sent it), so
  this tries every currently *active* Brevo integration — same set
  `BrevoPollingJob` polls — and aggregates whatever comes back. In the
  common single-account case that's one request; `messageId` is
  selective enough that a wrong account simply returns no events, not
  wrong data.
  """

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoClient
  alias PhoenixKit.Modules.Emails.BrevoEventNormalizer
  alias PhoenixKit.Modules.Emails.BrevoIntegrations
  alias PhoenixKit.Modules.Emails.Log
  alias PhoenixKit.Modules.Emails.SQSProcessor

  @doc """
  Fetches and processes events for a single Brevo-sent log right now.

  ## Returns

  - `{:ok, %{events_processed: n}}` — `n` may be `0` ("no new events")
  - `{:error, reason}` — a user-facing string, never includes credentials
  """
  @spec sync(Log.t()) ::
          {:ok, %{events_processed: non_neg_integer()}} | {:error, String.t()}
  def sync(%Log{provider: "brevo_api", aws_message_id: message_id})
      when not is_binary(message_id) or message_id == "" do
    {:error, "This email has no recoverable Brevo message id to look up yet."}
  end

  def sync(%Log{provider: "brevo_api"} = log) do
    if Emails.enabled?() do
      case BrevoIntegrations.active_integration_uuids() do
        [] ->
          {:error, "No active Brevo integration configured to check this email."}

        integration_uuids ->
          api_keys = resolve_api_keys(integration_uuids)
          do_sync(log, api_keys)
      end
    else
      {:error, "Email system is disabled. Please enable it in settings."}
    end
  end

  defp resolve_api_keys(integration_uuids) do
    Enum.flat_map(integration_uuids, fn uuid ->
      case BrevoIntegrations.resolve_api_key(uuid) do
        {:ok, api_key} -> [api_key]
        {:error, _reason} -> []
      end
    end)
  end

  defp do_sync(_log, []) do
    {:error, "No active Brevo integration configured to check this email."}
  end

  defp do_sync(log, api_keys) do
    events =
      api_keys
      |> Enum.flat_map(&fetch_for_key(&1, log))
      |> Enum.uniq()

    processed_count =
      events
      |> Enum.map(&process_event/1)
      |> Enum.count(&(&1 == :ok))

    {:ok, %{events_processed: processed_count}}
  end

  defp fetch_for_key(api_key, log) do
    params = [messageId: log.aws_message_id, days: days_for_log(log), sort: "desc"]

    case BrevoClient.fetch_events(api_key, params, req_options()) do
      {:ok, events} ->
        events

      {:error, reason} ->
        Logger.warning("BrevoOnDemandSync: fetch failed for one integration", %{
          reason: inspect(reason)
        })

        []
    end
  end

  defp process_event(brevo_event) do
    case BrevoEventNormalizer.normalize(brevo_event) do
      {:ok, event_data} ->
        case SQSProcessor.process_email_event(event_data) do
          {:ok, _result} -> :ok
          {:error, _reason} -> :error
        end

      :ignore ->
        :ignore

      {:error, _reason} ->
        :error
    end
  end

  # Brevo's `days` param is mutually exclusive with startDate/endDate and
  # capped at 90 (the API's own hard limit) — covers from the log's send
  # date through today, floored at 1 day and capped at 90.
  defp days_for_log(%Log{inserted_at: %DateTime{} = inserted_at}) do
    today = Date.utc_today()
    log_date = DateTime.to_date(inserted_at)
    age_days = Date.diff(today, log_date) + 1

    age_days |> max(1) |> min(90)
  end

  defp days_for_log(%Log{}), do: 90

  defp req_options do
    Application.get_env(:phoenix_kit_emails, :brevo_client_req_options, [])
  end
end
