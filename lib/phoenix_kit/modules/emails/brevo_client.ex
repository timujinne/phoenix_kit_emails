defmodule PhoenixKit.Modules.Emails.BrevoClient do
  @moduledoc """
  Thin wrapper around the Brevo transactional-email events API
  (`GET /v3/smtp/statistics/events`).

  Isolated from `BrevoPollingJob` so tests can stub the HTTP layer with
  `Req.Test` instead of hitting the real network: pass
  `req_options: [plug: {Req.Test, MyStubName}]`.
  """

  require Logger

  @events_url "https://api.brevo.com/v3/smtp/statistics/events"
  @http_timeout 15_000

  @doc """
  Fetches one page of events for the given date window.

  `params` is merged into the query string as-is — callers pass Brevo's
  real query keys (`startDate`, `endDate`, `limit`, `offset`, `sort`, ...).

  ## Returns

  - `{:ok, [event_map]}` — the `events` array from a 200 response (`[]`
    when the response has no `events` key, e.g. an empty page)
  - `{:error, :invalid_credentials}` — 401
  - `{:error, {:http_status, status}}` — any other non-200 status
  - `{:error, reason}` — transport-level failure
  """
  @spec fetch_events(String.t(), keyword(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_events(api_key, params, req_options \\ []) do
    request_opts =
      [
        headers: [{"api-key", api_key}],
        params: params,
        receive_timeout: @http_timeout
      ]
      |> Keyword.merge(req_options)

    case Req.get(@events_url, request_opts) do
      {:ok, %{status: 200, body: %{"events" => events}}} when is_list(events) ->
        {:ok, events}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, %{status: 401}} ->
        {:error, :invalid_credentials}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        Logger.error("BrevoClient: request failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end
end
