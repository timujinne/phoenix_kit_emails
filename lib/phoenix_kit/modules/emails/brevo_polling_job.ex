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
    with no consumption side-effect — this job tracks its own read
    position instead (see "Watermark cursor" below). Re-processing an
    already-seen event is still safe and cheap regardless:
    `Event.create_event/1`'s partial unique indexes (see
    `Event.changeset/2`) make it a no-op, not a duplicate row — the
    watermark exists for *performance and completeness* on top of that
    existing guarantee, not to provide it.

  ## Watermark cursor

  Brevo's `startDate`/`endDate` query params only accept whole calendar
  dates (`YYYY-MM-DD`) — there is no "give me events after this exact
  timestamp/offset" primitive. An early version of this job re-fetched
  the fixed `[yesterday, today]` window from `offset: 0` every cycle,
  which has two problems at volume: every already-processed event pays
  the full re-fetch + dedup-lookup cost again, and a sender producing
  more than `@max_pages_per_integration * page_limit()` events in that
  window (25,000 by default) can never reach its newest events — the
  page cap is always hit before the tail of an ever-re-fetched window is
  reached.

  Each integration's progress is now tracked as a persisted
  `%{date: Date.t(), offset: integer}` watermark
  (`Emails.get_brevo_watermark/1` / `set_brevo_watermark/3`, stored via
  `PhoenixKit.Settings`' JSON-by-prefix helpers — no dedicated table).
  Every request queries **a single day** (`startDate == endDate ==
  watermark.date`), never a growing window — this is the key property
  that makes `offset` mean the same thing across cycles. (A naive
  "just remember the offset" fix without this breaks at every day
  boundary: if `startDate` is recomputed as `yesterday()` each cycle the
  way the old code did, the window silently slides forward by one day
  every day, and a stale offset from window `[D-1, D]` gets replayed
  against the unrelated window `[D, D+1]` the next cycle — same
  numeric offset, different result set entirely.)

  A day only advances (offset resets to 0, `date` moves to the next
  day) once a short page (fewer than `page_limit()` events) is seen for
  it **and** it's strictly before today. Today's date never auto-closes
  from a short page alone — more events (opens/clicks/bounces on
  earlier sends) can land on it any time before midnight, and closing
  it early would permanently skip them (nothing ever re-visits a closed
  day by design — see the trailing re-check below for the one
  exception). The watermark is persisted after *every* page (not once
  at the end of a cycle), so a crash mid-cycle replays at most one page
  of already-processed (dedup-absorbed) events, not the whole cycle.

  ### Trailing safety re-check

  Whenever the watermark's `date` equals today — meaning the forward
  walk has already closed yesterday and moved on, and (unlike a still-
  lagging backlog) will never fetch yesterday again on its own — this
  job additionally re-scans **yesterday relative to right now**
  (`Date.add(today, -1)`) from `offset: 0` before advancing the
  watermark: a fixed one-day lookback with no cursor of its own (it
  never persists a position; there's nothing to remember, it always
  starts over at 0). This guards two distinct risks that both surface
  as "an event that belongs to a day the watermark has already closed
  and will never revisit":

    1. **Indexing lag.** Brevo's event log has been observed to lag
       real time by roughly 30–60 seconds. An event that occurs at
       23:59:50 can be indexed on Brevo's side a moment after midnight
       — by which point the watermark may have already closed
       yesterday with a short page that didn't yet include it.
    2. **`startDate`/`endDate` timezone ambiguity.** Brevo's API
       documentation states the returned `date` field is UTC, but does
       **not** document which timezone `startDate`/`endDate` are
       interpreted in — plausibly the receiving Brevo account's
       configured timezone rather than UTC. If so, this job's
       UTC-computed `today()` and Brevo's own day boundary can disagree
       by up to (but never more than) one calendar day — at any given
       instant, at most two calendar dates are "current" anywhere on
       Earth, so a one-day lookback is a sufficient, not merely
       heuristic, margin here. Chosen deliberately: extend the
       re-checked window rather than guess at a specific timezone
       (nothing in Brevo's docs settles it either way).

  A one-day lookback is a margin against both risks above as observed —
  sub-minute indexing lag, and at most a one-day timezone offset — not a
  general guarantee against arbitrarily late indexing. An event indexed
  more than 24h after it occurred would land on a day this re-check no
  longer reaches (that day has since closed too, and closed days are
  never revisited by design — see above). This is an accepted trade-off
  given the lag actually observed, not a gap this job tries to close.

  The re-check itself is capped at its own fixed
  `@trailing_recheck_page_budget` (2 pages), independent of the forward
  walk's budget — see "Per-cycle event cap" for why, and for the
  resulting trade-off: on a day whose total event count exceeds what
  that budget can page through (starting over at offset 0 every cycle —
  it keeps no cursor of its own), a late-indexed event sorted past that
  point won't be reached by the re-check either, on this or any later
  cycle. Widening this budget (or giving the re-check a remembered
  starting offset instead of always restarting at 0) would close that
  gap at the cost of the "own small budget" property this section
  exists to have — not done here; see the "Per-cycle event cap" section
  for the reasoning that led to a small fixed budget over an unbounded
  one.

  The `watermark.date == today` gate isn't a cost-cutting shortcut —
  skipping it in every other state is required for correctness of a
  different kind: cold start's forward walk *also* begins at
  `{Date.add(today, -1), 0}` (see below), and a still-lagging backlog's
  forward walk will reach yesterday itself in due course either way —
  re-scanning it here too would be the exact same request twice in one
  cycle, not extra safety. Once the gate condition is true it stays
  true, and gets re-checked, every cycle for as long as the forward
  walk sits on today (i.e. once a day, renewed daily as "today" itself
  advances) — not a one-time check right after the boundary, so there's
  no grace-window length to tune. It runs first when it runs at all,
  ahead of the forward watermark walk (see "Per-cycle event cap") — but
  on its own small fixed budget, not a share of the forward walk's, so
  it can never starve the forward walk regardless of how large
  yesterday turned out to be.

  ### Stale watermark cleanup

  A watermark is keyed by integration uuid and outlives the integration
  itself unless cleaned up — `perform/1` prunes any stored watermark
  whose integration uuid is no longer in the current cycle's active set
  (`active_brevo_integrations/0` — deleted, or explicitly excluded via
  `Emails.brevo_polling_excluded_integrations/0`) before running the
  cycle. Excluding an integration and later re-including it starts it
  over from cold-start rather than resuming a possibly very stale
  position — the same trade-off a first-time poll already makes, not a
  new one.

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
  cycle, from the correct watermark position rather than from the
  start) rather than the poll cycle growing unbounded. A backlog
  spanning several low-volume days can close out more than one of them
  in a single cycle — the cap is on total pages fetched, not on how
  many distinct days get walked.

  This budget is **not** shared with the trailing safety re-check —
  that has its own separate, much smaller
  `@trailing_recheck_page_budget` (2 pages). It used to draw from this
  same cap, which meant a single very high-volume yesterday could
  exhaust the entire cap on the re-check alone (it restarts from
  offset 0 every cycle, re-reading pages it already re-confirmed last
  cycle) and leave nothing for the forward walk to advance today with
  — stale `today` data every cycle for as long as that backlog lasted,
  not just a one-off. Giving the re-check its own small budget instead
  means it can only ever cost a couple of pages, at the trade-off
  described in "Trailing safety re-check" above (it may not reach the
  tail of an unusually large day).

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
  @trailing_recheck_page_budget 2
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
        integration_uuids = active_brevo_integrations()
        prune_stale_watermarks(integration_uuids)
        next_interval = run_cycle(integration_uuids)
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
        run_watermark_cycle(api_key, integration_uuid)
        :ok

      {:error, reason} ->
        Logger.error(
          "Brevo Polling Job: could not resolve credentials for integration #{integration_uuid}",
          %{reason: inspect(reason)}
        )

        :misconfigured
    end
  end

  # See moduledoc "Watermark cursor" for the full rationale. Order: the
  # trailing safety re-check (when it runs at all — see below) goes
  # first, so it isn't starved by a large forward backlog; whatever page
  # budget remains goes to advancing the real watermark.
  defp run_watermark_cycle(api_key, integration_uuid) do
    today = today_date()
    watermark = Emails.get_brevo_watermark(integration_uuid)

    # The trailing re-check only earns its cost when the forward walk has
    # actually moved PAST yesterday and won't naturally revisit it — i.e.
    # watermark.date == today. Any other state (cold start, or the
    # forward walk still mid-backlog at or before yesterday) means the
    # walk below is about to fetch that same day itself; re-scanning it
    # here first would just be the exact same request twice in one cycle.
    #
    # Capped at its own fixed @trailing_recheck_page_budget rather than
    # sharing the full @max_pages_per_integration cap — it restarts from
    # offset 0 every cycle (see moduledoc), so on a day with more events
    # than that budget covers, an unbounded trailing re-check would spend
    # its entire allowance re-reading pages it already re-confirmed on
    # the *previous* cycle, starving the forward walk of every page for
    # that whole cycle (stale `today` data, not lost data — see
    # moduledoc's "Per-cycle event cap").
    trailing_pages =
      if watermark && Date.compare(watermark.date, today) == :eq do
        trailing_date = Date.add(today, -1)
        trailing_budget = min(@trailing_recheck_page_budget, @max_pages_per_integration)

        {_status, _offset, pages} =
          drain_day(api_key, integration_uuid, trailing_date, 0, 0, trailing_budget)

        pages
      else
        0
      end

    remaining_budget = @max_pages_per_integration - trailing_pages

    if remaining_budget > 0 do
      {date, offset} =
        case watermark do
          %{date: date, offset: offset} ->
            {date, offset}

          # Cold start: same floor the old unconditional [yesterday, today]
          # window already guaranteed. No backfill needed — every
          # integration just takes one more legacy-shaped pass before
          # falling into watermark tracking from here on.
          nil ->
            {Date.add(today, -1), 0}
        end

      advance_watermark(api_key, integration_uuid, date, offset, today, remaining_budget, 0)
    end
  end

  # Fetches one page for `date`/`offset` and processes every event in it.
  # Shared by `drain_day/6` and `advance_watermark/7` — fetching and
  # processing a single page is identical between them; only what happens
  # *after* (recurse-and-discard vs. recurse-and-persist-the-watermark)
  # differs, which stays in each caller.
  defp fetch_and_process_page(api_key, integration_uuid, date, offset) do
    limit = page_limit()
    date_str = Date.to_iso8601(date)
    params = [startDate: date_str, endDate: date_str, sort: "asc", limit: limit, offset: offset]

    case BrevoClient.fetch_events(api_key, params, req_options()) do
      {:ok, events} ->
        Enum.each(events, &process_event/1)
        {:ok, events, limit}

      {:error, reason} ->
        Logger.error("Brevo Polling Job: failed to fetch events", %{
          integration_uuid: integration_uuid,
          date: date_str,
          offset: offset,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  # Fetches and processes pages of a single day starting at `offset`
  # until either a short page is seen (`:exhausted` — no more results
  # for this day as of now) or `budget` pages have been spent
  # (`:budget_exhausted`), or the request fails (`:error`). Shared by
  # the trailing re-check (which discards the result — it never
  # advances or persists) and `advance_watermark/7` (which uses it to
  # decide whether to close the day out).
  defp drain_day(_api_key, _integration_uuid, _date, offset, pages_used, budget)
       when pages_used >= budget do
    {:budget_exhausted, offset, pages_used}
  end

  defp drain_day(api_key, integration_uuid, date, offset, pages_used, budget) do
    case fetch_and_process_page(api_key, integration_uuid, date, offset) do
      {:ok, events, limit} ->
        pages_used = pages_used + 1

        if length(events) == limit do
          drain_day(api_key, integration_uuid, date, offset + limit, pages_used, budget)
        else
          {:exhausted, offset + length(events), pages_used}
        end

      {:error, _reason} ->
        {:error, offset, pages_used}
    end
  end

  defp advance_watermark(_api_key, integration_uuid, date, offset, _today, budget, pages_used)
       when pages_used >= budget do
    Logger.warning(
      "Brevo Polling Job: hit the #{@max_pages_per_integration}-page cap for integration " <>
        "#{integration_uuid} at #{Date.to_iso8601(date)}, offset #{offset} — remaining " <>
        "events will be picked up next cycle"
    )
  end

  defp advance_watermark(api_key, integration_uuid, date, offset, today, budget, pages_used) do
    case fetch_and_process_page(api_key, integration_uuid, date, offset) do
      {:ok, events, limit} ->
        pages_used = pages_used + 1

        if length(events) == limit do
          new_offset = offset + limit
          persist_watermark(integration_uuid, date, new_offset)

          advance_watermark(
            api_key,
            integration_uuid,
            date,
            new_offset,
            today,
            budget,
            pages_used
          )
        else
          advance_past_short_page(
            api_key,
            integration_uuid,
            date,
            offset,
            today,
            budget,
            pages_used
          )
        end

      {:error, _reason} ->
        :ok
    end
  end

  # A short page came back for `date`. Only a day strictly before today
  # is safe to close (advance past) — today's date never auto-closes
  # from a short page alone, since more events can still land on it
  # before midnight (see moduledoc). Either way the watermark is
  # persisted, keeping "touched after every successful page" uniform.
  defp advance_past_short_page(api_key, integration_uuid, date, offset, today, budget, pages_used) do
    if Date.compare(date, today) == :lt do
      next_date = Date.add(date, 1)
      persist_watermark(integration_uuid, next_date, 0)

      if pages_used < budget do
        advance_watermark(api_key, integration_uuid, next_date, 0, today, budget, pages_used)
      end
    else
      persist_watermark(integration_uuid, date, offset)
    end
  end

  # Every watermark write goes through here so a failed persist is never
  # silent. Nothing else observes or retries this specific write — a
  # failure here leaves the cursor at its last-successfully-persisted
  # position (this page's events were already processed and are
  # dedup-safe to re-process — see moduledoc — so nothing is lost) but
  # an operator watching for a stuck integration otherwise has no signal
  # that this happened at all.
  defp persist_watermark(integration_uuid, date, offset) do
    case Emails.set_brevo_watermark(integration_uuid, date, offset) do
      {:ok, _setting} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Brevo Polling Job: failed to persist watermark for integration " <>
            "#{integration_uuid} at #{Date.to_iso8601(date)}, offset #{offset}: " <>
            "#{inspect(reason)} — this page will be re-fetched (safely — see moduledoc " <>
            "on dedup) next cycle"
        )
    end
  end

  # Deletes any stored watermark whose integration uuid isn't in this
  # cycle's active set — the integration was deleted, or explicitly
  # excluded from polling. See moduledoc "Stale watermark cleanup".
  defp prune_stale_watermarks(active_integration_uuids) do
    active = MapSet.new(active_integration_uuids)

    Emails.list_brevo_watermark_integration_uuids()
    |> Enum.reject(&MapSet.member?(active, &1))
    |> Enum.each(fn stale_uuid ->
      Emails.delete_brevo_watermark(stale_uuid)

      Logger.info(
        "Brevo Polling Job: pruned stale watermark for integration #{stale_uuid} " <>
          "(deleted, or excluded from polling)"
      )
    end)
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

  defp today_date, do: UtilsDate.utc_now() |> DateTime.to_date()

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
