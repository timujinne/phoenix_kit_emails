defmodule PhoenixKit.Modules.Emails.SQSPollingManager do
  @moduledoc """
  Manager module for SQS polling via Oban jobs.

  This module provides a unified API for managing SQS polling that can be
  enabled/disabled dynamically without application restart.

  ## Features

  - **Enable/Disable Polling**: Start or stop polling without restart
  - **Manual Triggering**: Force immediate polling when needed
  - **Status Monitoring**: Get current polling status and job information
  - **Settings Integration**: Automatically uses PhoenixKit Settings
  - **Interval Control**: Dynamically adjust polling frequency

  ## Architecture

  Instead of using a GenServer, this manager uses Oban jobs for polling:
  - Each job polls SQS once and schedules the next job
  - Jobs check settings before executing (dynamic control)
  - No need to restart GenServer when settings change

  ## Usage

      # Enable polling
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      {:ok, %Oban.Job{}}

      # Disable polling
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      :ok

      # Check status
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.status()
      %{
        enabled: true,
        interval_ms: 5000,
        pending_jobs: 1,
        last_run: ~U[2025-09-20 15:30:45Z],
        queue_url: "https://sqs.eu-north-1.amazonaws.com/..."
      }

      # Trigger immediate poll
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()
      {:ok, %Oban.Job{}}

      # Change polling interval
      iex> PhoenixKit.Modules.Emails.SQSPollingManager.set_polling_interval(3000)
      {:ok, %Setting{}}

  ## Integration

  This manager is the single control surface for SQS polling: it drives the
  Oban `SQSPollingJob`. `enable_polling/0` and `disable_polling/0` back the
  admin UI toggle. `poll_now/0` and `set_polling_interval/1` are part of the
  public consumer API (no admin-UI caller today); they are safe to call
  directly from host applications.
  """

  @behaviour PhoenixKit.Modules.Emails.EventTracker

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.AwsIntegrations
  alias PhoenixKit.Modules.Emails.SQSPollingJob

  ## --- EventTracker behaviour ---
  #
  # Thin wrappers over the existing SQSPollingJob/Manager logic — see
  # PhoenixKit.Modules.Emails.EventTracker's moduledoc for the full
  # eligible?/enabled? split rationale.

  @impl PhoenixKit.Modules.Emails.EventTracker
  def provider_kind, do: "aws_ses"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def label, do: "Amazon SES"

  @impl PhoenixKit.Modules.Emails.EventTracker
  def eligible?, do: SQSPollingJob.pollable_ignoring_toggle?()

  @impl PhoenixKit.Modules.Emails.EventTracker
  def enabled?, do: Emails.sqs_polling_enabled?()

  @impl PhoenixKit.Modules.Emails.EventTracker
  def poll_cycle(_context), do: SQSPollingJob.perform(%Oban.Job{})

  @impl PhoenixKit.Modules.Emails.EventTracker
  def interval_ms, do: Emails.get_sqs_config().polling_interval_ms

  # Matches set_polling_interval/1's own guard below — single source of
  # truth would be nicer, but the guard needs a literal for the function
  # clause match; kept in sync by hand (both change together, rarely).
  @impl PhoenixKit.Modules.Emails.EventTracker
  def min_interval_ms, do: 1_000

  @impl PhoenixKit.Modules.Emails.EventTracker
  def worker, do: SQSPollingJob

  ## --- Optional EventTracker callbacks ---
  #
  # integration_count/0, accounts/0 and toggle_account_polling/1 are formal
  # @optional_callbacks on EventTracker; the panel never calls them directly
  # on a tracker module, always through EventTracker.integration_count/1,
  # accounts/1, toggle_account_polling/2, which supply a safe
  # default/no-op/fallback for a tracker that skips them. SES used to skip
  # accounts/0 and toggle_account_polling/1 because it had no multi-account
  # concept (one "SES credentials source" picker, not a list); it does now —
  # every `aws_ses` connection an enabled SendProfile points at is an account
  # with its own queue and keys (see
  # `PhoenixKit.Modules.Emails.AwsIntegrations`).
  #
  # last_polled_at/0 is still skipped: SQS's polling cadence is seconds, so
  # EventTracker's generic Oban-history derivation still finds a `completed`
  # job before the Pruner removes it — the reason BrevoPollingManager needs
  # its own durable timestamp does not apply here.

  # Everything SES-specific — credentials source, per-account queues, Setup
  # Infrastructure, SQS worker tuning — renders inside this tracker's own
  # expanded row in the Delivery event tracking panel. It used to be a third,
  # sibling section on the same settings page, which read as a peer of the
  # tracker table while actually being a detail of one of its rows.
  #
  # A module reference, not an alias: the component belongs to the Web layer
  # and aliasing it here would suggest this manager depends on the admin UI
  # to work. It does not — this callback is the panel asking the tracker
  # "who renders you", and nothing else in this module touches it.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def settings_component, do: PhoenixKit.Modules.Emails.Web.SettingsSections.AmazonSesSqs

  # Number of accounts with somewhere to poll — the admin panel's "N active
  # integrations" Integration-column count. Counts `configured_accounts/0`
  # rather than active integrations so it keeps mirroring eligible?/0 (an
  # account with no queue is not "a working SES event source", the property
  # this column has always reported) AND still reports the legacy
  # single-queue deployment, which has no integration to count but is very
  # much polling one thing.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def integration_count, do: length(SQSPollingJob.configured_accounts())

  # Per-account opt-out list for the admin panel's Accounts column:
  # {uuid, name, polled?} for every currently-active SES account. The
  # legacy single-queue deployment contributes no row — it has no uuid to
  # name it by, and nothing to toggle.
  #
  # `length(accounts/0)` and `integration_count/0` deliberately DISAGREE, and
  # the panel renders them in different columns for different questions:
  #
  #   * `accounts/0` answers "which accounts can I toggle?" — every active
  #     SES account, including one with no queue configured yet.
  #   * `integration_count/0` answers "is there a working event source?" —
  #     it mirrors eligible?/0, so it counts only accounts with somewhere to
  #     poll, and counts the legacy single-queue deployment as 1 even though
  #     it has no account to name.
  #
  # The two coincide on a fully configured multi-account install, which is
  # why the difference is easy to mistake for a bug. It is not: making
  # either follow the other would break the column it belongs to.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def accounts do
    excluded = MapSet.new(Emails.get_sqs_polling_excluded_integrations())

    AwsIntegrations.active_integrations_with_names()
    |> Enum.map(fn {uuid, name} -> {uuid, name, not MapSet.member?(excluded, uuid)} end)
  end

  # Flips one account's polling opt-out (see accounts/0). A uuid that isn't
  # a currently-active aws_ses integration (stale, already removed, or
  # simply forged in a phx-click) is ignored rather than written into the
  # exclusion setting — that list should only ever contain uuids accounts/0
  # could plausibly have shown a checkbox for.
  @impl PhoenixKit.Modules.Emails.EventTracker
  def toggle_account_polling(uuid) do
    if uuid in AwsIntegrations.active_integration_uuids() do
      excluded = Emails.get_sqs_polling_excluded_integrations()

      new_excluded =
        if uuid in excluded, do: List.delete(excluded, uuid), else: [uuid | excluded]

      Emails.set_sqs_polling_excluded_integrations(new_excluded)
    else
      {:ok, :ignored}
    end
  end

  ## --- Admin panel duck-typed extras (informal, not EventTracker callbacks) ---
  #
  # enable_polling/0, disable_polling/0, poll_now/0, set_polling_interval/1,
  # status/0 below — same informal "Manager API shared shape" convention
  # spec §3 documents, not part of the formal EventTracker behaviour.

  @doc """
  Enables SQS polling by setting the configuration and starting the first job.

  Three writes — `email_ses_events`, `sqs_polling_enabled` and the first
  Oban job — land in ONE transaction. They used to run as three bare
  steps chained by `with`, so a failure at step two or three left
  `email_ses_events` flipped on by a click that reported an error: the
  operator saw "failed to enable", the install silently gained an
  eligibility flag it never had, and nothing on the page said so.
  `Settings.update_settings_batch/1` is the obvious tool and the wrong
  one here — it writes `key`/`value` only, so on an install where these
  rows do not exist yet it would create them without the `email_system`
  module tag the settings page groups by.

  Cache invalidation cuts both ways here. On a rollback it stays valid:
  the writers only CLEAR entries, so the next read comes from the
  rolled-back row rather than a stale cached one. On success it is not
  enough on its own — the writers clear inside the transaction, before
  the commit is visible, so a reader that misses the cache in that window
  would cache the pre-commit value and keep it for the cache's whole TTL.
  Both keys are therefore invalidated again after the commit.

  ## Returns

  - `{:ok, job}` - Successfully enabled and started first job
  - `{:error, reason}` - Nothing was written; both settings keep their prior values

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      {:ok, %Oban.Job{id: 1, queue: "sqs_polling"}}
  """
  def enable_polling do
    Logger.info("SQS Polling Manager: Enabling polling")

    repo = PhoenixKit.RepoHelper.repo()

    result =
      repo.transaction(fn ->
        # `email_ses_events` is the OTHER half of this switch: `should_poll?/0`
        # requires both, and having them in two places meant an operator could
        # turn tracking on here and get nothing, with no hint that a checkbox in
        # another section still said no. One switch now owns both — turning it
        # ON. Turning it off deliberately does not clear the flag; see
        # `disable_polling/0` and `EventTracker`'s moduledoc for why.
        with {:ok, _} <- Emails.set_ses_events(true),
             {:ok, _setting} <- Emails.set_sqs_polling(true),
             {:ok, job} <- insert_poll_job() do
          job
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, job} ->
        # The writers invalidate inside the transaction, i.e. BEFORE the commit
        # is visible. A reader that misses the cache in that window reads the
        # pre-commit value from the database and caches it — and nothing would
        # invalidate it again for the cache's whole TTL. Re-invalidating here,
        # after the commit, closes that window; it is a delete, so it is safe
        # to repeat.
        PhoenixKit.Cache.invalidate(:settings, "email_ses_events")
        PhoenixKit.Cache.invalidate(:settings, "sqs_polling_enabled")

        Logger.info("SQS Polling Manager: Polling enabled and first job started")
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("SQS Polling Manager: Failed to enable polling", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Disables SQS polling by updating the configuration.

  Only `sqs_polling_enabled` is cleared. `email_ses_events` — which
  `enable_polling/0` turns on — is deliberately left alone, and the
  asymmetry is the point: enabling asserts "SES event tracking is a
  thing on this install", which stays true while polling is paused, and
  the same flag also gates the SNS webhook path
  (`Emails.Web.WebhookController`), which has nothing to do with SQS
  polling. Clearing it here would silently switch off webhook ingestion
  from a button labelled "stop polling". It keeps its own control in the
  Email Tracking settings section (`Web.SettingsSections.EmailTracking`) for an operator who really does mean
  "no SES events at all". See `EventTracker`'s moduledoc, which spells
  out why an eligibility flag otherwise must not move with an operator
  toggle.

  No explicit job cancellation: `SQSPollingJob.perform/1` checks
  `should_poll?/0` before doing any work AND before self-scheduling its
  next cycle (see that module). At most one already-queued job fires
  once more, sees polling disabled, does nothing, and does not
  re-schedule — the chain dies on its own within one cycle. That one
  harmless no-op run is the accepted cost of not doing a manual DELETE
  here.

  ## Returns

  - `:ok` - Successfully disabled

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()
      :ok
  """
  def disable_polling do
    Logger.info("SQS Polling Manager: Disabling polling")

    case Emails.set_sqs_polling(false) do
      {:ok, _setting} ->
        Logger.info("SQS Polling Manager: Polling disabled")
        :ok

      {:error, reason} ->
        Logger.error("SQS Polling Manager: Failed to disable polling", %{
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Sets the polling interval in milliseconds.

  The new interval will be used for subsequent job scheduling.

  ## Parameters

  - `interval_ms` - Interval in milliseconds (minimum 1000ms)

  ## Returns

  - `{:ok, setting}` - Successfully updated
  - `{:error, reason}` - Failed to update

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.set_polling_interval(3000)
      {:ok, %Setting{}}
  """
  def set_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms >= 1000 do
    Logger.info("SQS Polling Manager: Setting polling interval to #{interval_ms}ms")
    Emails.set_sqs_polling_interval(interval_ms)
  end

  def set_polling_interval(interval_ms) do
    {:error, "Invalid interval: #{interval_ms}. Must be >= 1000ms"}
  end

  @doc """
  Triggers an immediate polling job.

  This creates a new job that will execute as soon as possible,
  regardless of the normal polling schedule.

  The job carries `args: %{"forced" => true}`, which
  `SQSPollingJob.perform/1` honours by bypassing the
  `sqs_polling_enabled` toggle for that single cycle (it still respects
  the system switch, the SES-events switch, and the sender-aware gate).
  Without it a manual poll while the toggle is off would insert a job
  that runs, sees polling disabled, and silently does nothing. The
  distinct args also keep this insert in its own uniqueness namespace,
  so it never moves or cancels the regular chain's next scheduled tick
  — see `insert_forced_poll_job/0`.

  ## Returns

  - `{:ok, job}` - Successfully created immediate job
  - `{:error, reason}` - Failed to create job

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()
      {:ok, %Oban.Job{}}
  """
  def poll_now do
    Logger.info("SQS Polling Manager: Triggering immediate poll")

    unless polling_enabled?() do
      Logger.warning("SQS Polling Manager: Polling is disabled, but executing manual poll")
    end

    case insert_forced_poll_job() do
      {:ok, job} ->
        Logger.info("SQS Polling Manager: Immediate poll job created", %{job_id: job.id})
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("SQS Polling Manager: Failed to create immediate poll job", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Returns the current status of SQS polling.

  ## Returns

  A map with:
  - `enabled` - Whether polling is enabled
  - `interval_ms` - Current polling interval
  - `pending_jobs` - Number of scheduled jobs
  - `last_run` - Timestamp of last completed job (if any)
  - `queue_url` - Configured SQS queue URL

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.status()
      %{
        enabled: true,
        interval_ms: 5000,
        pending_jobs: 1,
        last_run: ~U[2025-09-20 15:30:45Z],
        queue_url: "https://sqs.eu-north-1.amazonaws.com/..."
      }
  """
  def status do
    config = Emails.get_sqs_config()

    pending_jobs = count_pending_jobs()
    last_completed = get_last_completed_job()

    %{
      enabled: config.polling_enabled,
      interval_ms: config.polling_interval_ms,
      pending_jobs: pending_jobs,
      last_run: last_completed && last_completed.completed_at,
      queue_url: config.queue_url,
      aws_region: config.aws_region,
      max_messages_per_poll: config.max_messages_per_poll,
      system_enabled: Emails.enabled?(),
      ses_events_enabled: Emails.ses_events_enabled?()
    }
  end

  ## --- Private Functions ---

  # Insert an immediately-available polling job to start the chain on
  # enable_polling/0. (poll_now/0 uses insert_forced_poll_job/0 below —
  # deliberately a separate insert, see there.)
  #
  # A per-call unique:/replace: override, NOT the job's own worker-level
  # default (which only covers :scheduled — see SQSPollingJob's moduledoc).
  # This one also covers :available, so a double-click or an enable while a
  # next-tick is already queued collapses into ONE row instead of two: on a
  # conflict, `replace:` moves the EXISTING job's scheduled_at to right now
  # (whichever state it's in — :scheduled or already :available) rather than
  # leaving a stray future job alongside a fresh immediate one. `:executing`
  # is deliberately excluded here too, same self-conflict reason as the
  # worker-level default; a job already executing when this fires just gets
  # a genuinely new, separate immediate job queued right behind it, which is
  # the correct "poll now" behavior, not a bug.
  #
  # `schedule_in: 0` is explicit and load-bearing, not decorative: Oban's
  # `replace:` only copies a field that's actually present in the NEW
  # insert's changeset changes (`Job.put_scheduling/2`), and a bare
  # `new(%{})` with no schedule option leaves `:scheduled_at` untouched —
  # `replace: [scheduled: [:scheduled_at]]` would then have nothing to
  # copy onto a conflicting future job, silently failing to move it up.
  # (A job with `scheduled_at` == now lands in Oban's `:scheduled` state,
  # not `:available` — see `Job.normalize_state/1` — but its
  # `scheduled_at` has already "elapsed", so Oban's staging sweep
  # (~1s cadence) picks it up next tick regardless; functionally
  # immediate for this use case.)
  defp insert_poll_job do
    %{}
    |> SQSPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  # `args: %{"forced" => true}` differs from the regular chain's `%{}` in two
  # load-bearing ways (mirrors BrevoPollingManager.insert_forced_poll_job/0):
  #
  #   1. `SQSPollingJob.perform/1` treats it as "run this cycle even though
  #      the sqs_polling_enabled toggle is off". Reusing insert_poll_job/0
  #      here made poll_now/0 a silent no-op whenever polling was disabled —
  #      the one case an operator is most likely to click it — even though
  #      poll_now/0 logs "Polling is disabled, but executing manual poll".
  #   2. Oban's unique check matches on args by default, so this can only
  #      ever conflict with ANOTHER forced job, never the regular chain.
  #      Repeated poll_now/0 calls collapse into one (moved to run now via
  #      replace:) without touching the regular chain's own next scheduled
  #      tick — which sharing insert_poll_job/0 did, resetting the cadence
  #      on every manual poll.
  #
  # `schedule_in: 0` — same reason as insert_poll_job/0 above.
  defp insert_forced_poll_job do
    %{"forced" => true}
    |> SQSPollingJob.new(
      schedule_in: 0,
      unique: [period: :infinity, states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  # Check if polling is currently enabled
  defp polling_enabled? do
    Emails.sqs_polling_enabled?()
  end

  # Count pending/scheduled SQS polling jobs
  defp count_pending_jobs do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = SQSPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end

  # Get the last completed job
  defp get_last_completed_job do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = SQSPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state == "completed",
      order_by: [desc: j.completed_at],
      limit: 1
    )
    |> repo.one()
  rescue
    _ -> nil
  end
end
