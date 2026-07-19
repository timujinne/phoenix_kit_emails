defmodule PhoenixKit.Modules.Emails.BrevoPollingJob do
  @moduledoc """
  Oban worker for polling the Brevo transactional-email events API.

  Mirrors `SQSPollingJob`'s self-scheduling chain (see that module's
  `@moduledoc` for the general shape/rationale — the self-reschedule
  dedup, `unique` window, and misconfig back-off all apply identically
  here) with two differences dictated by Brevo's API instead of SQS's:

  - **Sender-aware gate**: SQS polls unconditionally once enabled; Brevo
    only fetches events while at least one *enabled*
    `PhoenixKit.Email.SendProfile` actually points at a `"brevo_api"`
    integration — an idle Brevo integration with no active profile has
    nothing to correlate events against, so polling it is pure waste
    (and, unlike SQS's long-poll, would burn Brevo API quota on a timer).
    The chain still keeps re-scheduling itself while `brevo_events_enabled`
    stays on even when there are zero active profiles right now — a
    profile added later must not require a manual re-trigger to be picked
    up.
  - **No message ack step**: SQS deletes each message after processing to
    avoid redelivery. Brevo's events endpoint is a plain paginated report
    with no consumption side-effect — the SAME date window (yesterday +
    today) is re-fetched every cycle. Re-processing an already-seen event
    is safe and cheap: `Event.create_event/1`'s partial unique indexes
    (see `Event.changeset/2`) make it a no-op, not a duplicate row.

  ## Multi-integration

  More than one Brevo `Integrations` connection can exist (e.g. two
  distinct Brevo accounts, each with its own `SendProfile`). Each cycle
  polls every *distinct* integration referenced by an enabled Brevo
  profile — not once per profile, since profiles may share an
  integration and its API key. If *any* integration in the cycle turns
  out to be misconfigured (missing/invalid credentials), the *whole*
  cycle's next poll backs off to `@misconfig_backoff_ms` rather than the
  configured interval — same rationale as `SQSPollingJob`, and a
  deliberate choice, not an oversight: a per-integration backoff would
  need per-integration scheduling state this self-scheduling chain
  doesn't have, and a broken integration is expected to be rare/
  transient enough that briefly slowing the whole cycle is an acceptable
  trade for the simplicity of one shared interval.

  ## Per-cycle event cap

  Each integration is capped at `@max_pages_per_integration` (10) pages
  of `@default_page_limit` (2500, overridable — see `page_limit/0`)
  events per cycle — at most 25,000 events per integration per poll. A
  sender busy enough to exceed that in one `polling_interval_ms` window
  will lag (the cap logs a warning and picks up the remainder next
  cycle) rather than the poll cycle growing unbounded. Not expected to
  matter at typical volumes; flagged here because it's silent otherwise.

  ## Oban queue configuration

  Requires a `:brevo_polling` Oban queue in the *host app's* config,
  same as `:sqs_polling` already does:

      config :your_app, Oban,
        queues: [
          brevo_polling: 1  # concurrency MUST stay 1 — the self-scheduling
                             # chain assumes only one cycle runs at a time;
                             # see SQSPollingJob's queue config docs for why
        ]
  """

  use Oban.Worker,
    queue: :brevo_polling,
    max_attempts: 3,
    unique: [period: 10, states: [:scheduled]]

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoClient
  alias PhoenixKit.Modules.Emails.BrevoEventNormalizer
  alias PhoenixKit.Modules.Emails.BrevoIntegrations
  alias PhoenixKit.Modules.Emails.SQSProcessor
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @default_page_limit 2500
  @max_pages_per_integration 10
  @misconfig_backoff_ms 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # `forced: true` (BrevoPollingManager.poll_now/0) bypasses the
    # brevo_events_enabled toggle specifically — an operator asking for
    # data right now shouldn't be silently ignored just because the
    # background chain is off — but never bypasses Emails.enabled?/0
    # (system disabled) or the sender-aware profile gate inside
    # run_cycle/1. schedule_next_poll/1 re-checks should_poll?/0 on its
    # own, so a forced run while the toggle is off still runs once
    # without resurrecting the self-scheduling chain.
    forced? = Map.get(args || %{}, "forced", false)

    cond do
      not Emails.enabled?() ->
        Logger.debug("Brevo Polling Job: system disabled, skipping cycle")
        :ok

      forced? or Emails.brevo_events_enabled?() ->
        next_interval = run_cycle(active_brevo_integrations())
        schedule_next_poll(next_interval)
        :ok

      true ->
        Logger.debug("Brevo Polling Job: polling disabled, skipping cycle")
        :ok
    end
  end

  @doc """
  Cancels all scheduled Brevo polling jobs. Called when polling is
  disabled to immediately clean up pending jobs.
  """
  @spec cancel_scheduled() :: {:ok, non_neg_integer()}
  def cancel_scheduled do
    {count, _} = delete_queued_jobs()
    Logger.info("BrevoPollingJob: Cancelled #{count} scheduled jobs")
    {:ok, count}
  end

  @doc """
  Returns the Oban `worker` column value for this job. Single source of
  truth for callers that query `Oban.Job` by worker name (e.g.
  `BrevoPollingManager`).
  """
  @spec worker_name() :: String.t()
  def worker_name, do: inspect(__MODULE__)

  ## --- Private Functions ---

  defp should_poll? do
    Emails.enabled?() and Emails.brevo_events_enabled?()
  end

  defp run_cycle([]) do
    Logger.debug("Brevo Polling Job: No enabled Brevo send profiles, skipping cycle")
    # Still recorded even though nothing was fetched: an operator watching
    # the status panel needs to see the chain is alive and ticking, not a
    # last_polled_at frozen from before the last profile was disabled.
    Emails.set_brevo_last_polled_at(UtilsDate.utc_now())
    Emails.get_brevo_polling_interval()
  end

  defp run_cycle(integration_uuids) do
    Logger.debug("Brevo Polling Job: Starting polling cycle", %{
      integrations: length(integration_uuids)
    })

    results = Enum.map(integration_uuids, &poll_integration/1)
    Emails.set_brevo_last_polled_at(UtilsDate.utc_now())

    if Enum.any?(results, &(&1 == :misconfigured)) do
      Logger.error("Brevo Polling Job: one or more integrations misconfigured, backing off")
      @misconfig_backoff_ms
    else
      Emails.get_brevo_polling_interval()
    end
  end

  # Every enabled send profile pointed at a "brevo_api" integration,
  # minus any the operator explicitly excluded from polling (per-account
  # opt-out — see Emails.brevo_polling_excluded_integrations/0) — the
  # sender-aware gate.
  defp active_brevo_integrations do
    excluded = MapSet.new(Emails.get_brevo_polling_excluded_integrations())

    BrevoIntegrations.active_integration_uuids()
    |> Enum.reject(&MapSet.member?(excluded, &1))
  end

  @spec poll_integration(String.t()) :: :ok | :misconfigured
  defp poll_integration(integration_uuid) do
    case BrevoIntegrations.resolve_api_key(integration_uuid) do
      {:ok, api_key} ->
        fetch_page(api_key, integration_uuid, 0, 0)
        :ok

      {:error, reason} ->
        Logger.error(
          "Brevo Polling Job: could not resolve credentials for integration #{integration_uuid}",
          %{reason: inspect(reason)}
        )

        :misconfigured
    end
  end

  defp fetch_page(_api_key, integration_uuid, offset, page_count)
       when page_count >= @max_pages_per_integration do
    Logger.warning(
      "Brevo Polling Job: hit the #{@max_pages_per_integration}-page cap for integration " <>
        "#{integration_uuid} at offset #{offset} — remaining events will be picked up next cycle"
    )
  end

  defp fetch_page(api_key, integration_uuid, offset, page_count) do
    limit = page_limit()

    params = [
      startDate: yesterday(),
      endDate: today(),
      sort: "asc",
      limit: limit,
      offset: offset
    ]

    case BrevoClient.fetch_events(api_key, params, req_options()) do
      {:ok, events} ->
        Enum.each(events, &process_event/1)

        if length(events) == limit do
          fetch_page(api_key, integration_uuid, offset + limit, page_count + 1)
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("Brevo Polling Job: failed to fetch events", %{
          integration_uuid: integration_uuid,
          reason: inspect(reason)
        })
    end
  end

  defp process_event(brevo_event) do
    case BrevoEventNormalizer.normalize(brevo_event) do
      {:ok, event_data} ->
        case SQSProcessor.process_email_event(event_data) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.warning("Brevo Polling Job: failed to process event", %{
              reason: inspect(reason),
              message_id: get_in(event_data, ["mail", "messageId"])
            })
        end

      :ignore ->
        :ok

      {:error, reason} ->
        Logger.warning("Brevo Polling Job: could not normalize event", %{
          reason: inspect(reason),
          raw_event_type: brevo_event["event"]
        })
    end
  end

  defp yesterday,
    do: UtilsDate.utc_now() |> DateTime.add(-1, :day) |> DateTime.to_date() |> Date.to_iso8601()

  defp today, do: UtilsDate.utc_now() |> DateTime.to_date() |> Date.to_iso8601()

  # Test seam: tests set `config :phoenix_kit_emails, :brevo_client_req_options,
  # plug: {Req.Test, SomeStubName}` to intercept BrevoClient's HTTP call
  # without a real network round trip. Empty (real network) in production.
  defp req_options do
    Application.get_env(:phoenix_kit_emails, :brevo_client_req_options, [])
  end

  # Test seam: tests can shrink this well below Brevo's real 2500 so a
  # pagination cycle doesn't require fabricating thousands of fixture
  # events. Both the query param and the "was this a full page" check use
  # the same value, so they stay consistent with whatever's configured.
  defp page_limit do
    Application.get_env(:phoenix_kit_emails, :brevo_page_limit, @default_page_limit)
  end

  defp delete_queued_jobs do
    worker = worker_name()

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.state in ["available", "scheduled"])
    |> get_repo().delete_all()
  end

  defp get_repo, do: PhoenixKit.RepoHelper.repo()

  defp schedule_next_poll(interval_ms) do
    if should_poll?() do
      delete_queued_jobs()

      %{}
      |> __MODULE__.new(schedule_in: max(div(interval_ms, 1000), 1))
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Logger.debug("Brevo Polling Job: next poll scheduled in #{interval_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("Brevo Polling Job: failed to schedule next poll", %{
            reason: inspect(reason)
          })

          :ok
      end
    else
      Logger.debug("Brevo Polling Job: polling disabled, not scheduling next poll")
      :ok
    end
  end
end
