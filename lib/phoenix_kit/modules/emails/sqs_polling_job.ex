defmodule PhoenixKit.Modules.Emails.SQSPollingJob do
  @moduledoc """
  Oban worker for polling AWS SQS queue for email events.

  This is the sole SQS poller: an Oban-based approach that allows dynamic
  enabling/disabling without an application restart (see `SQSPollingManager`).

  ## Architecture

  ```
  AWS SES → SNS Topic → SQS Queue → SQSPollingJob (Oban) → SQSProcessor → Database
  ```

  ## Features

  - **Dynamic Configuration**: Automatically responds to settings changes without restart
  - **Oban Integration**: Uses Oban's job system for reliable background processing
  - **Self-Scheduling**: Each job schedules the next polling cycle
  - **Batch Processing**: Process up to 10 messages at a time
  - **Error Handling**: Retry logic with Dead Letter Queue
  - **Settings-Based Control**: Polling can be enabled/disabled via Settings

  ## Configuration

  All settings are retrieved from PhoenixKit Settings:

  - `sqs_polling_enabled` - enable/disable polling (checked before each cycle)
  - `sqs_polling_interval_ms` - interval between polling cycles
  - `sqs_max_messages_per_poll` - maximum messages per batch
  - `sqs_visibility_timeout` - time for message processing
  - `aws_sqs_queue_url` - SQS queue URL
  - `aws_region` - AWS region

  ## Usage

      # Enable polling (starts first job)
      PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()

      # Disable polling (stops scheduling new jobs)
      PhoenixKit.Modules.Emails.SQSPollingManager.disable_polling()

      # Trigger immediate polling
      PhoenixKit.Modules.Emails.SQSPollingManager.poll_now()

      # Check status
      PhoenixKit.Modules.Emails.SQSPollingManager.status()

  ## Oban Queue Configuration

  Add to your `config/config.exs`:

      config :your_app, Oban,
        repo: YourApp.Repo,
        queues: [
          sqs_polling: 1  # Only one concurrent polling job
        ]

  ## Implementation Notes

  - Uses a short `unique` window to prevent duplicate submissions
  - Schedules next job only if polling is enabled
  - Uses `SQSProcessor` for event processing
  """

  use Oban.Worker,
    queue: :sqs_polling,
    max_attempts: 3,
    # Short unique window to coalesce accidental double-submits (e.g. double
    # clicking the toggle, or schedule_next_poll's delete-then-insert racing an
    # enable_polling insert). It is only a backstop for *near-simultaneous*
    # inserts — a full cycle apart they fall outside the window, so the single
    # queued job is instead guaranteed by delete_queued_jobs/0 in
    # schedule_next_poll (see there).
    #
    # NOTE: `:executing` is intentionally NOT in the states list. The chain
    # works by an executing job inserting the next one; if `:executing` were
    # included, that self-reschedule would be deduped against the still-running
    # job and the chain would stall. Worse, a job orphaned in `:executing` by a
    # hard crash (SIGKILL mid-poll) would permanently block every future insert,
    # killing polling until manual intervention.
    #
    # We match only `[:scheduled]`, which is exactly enough: self-scheduled jobs
    # always land in `:scheduled` (interval >= 1000ms ⇒ schedule_in >= 1s, never
    # `:available`), so this dedups the self-reschedule chain; the immediate
    # (`:available`) job from enable_polling/0 is already coalesced by
    # delete_queued_jobs/0 cancelling queued jobs before inserting. A wider list
    # (e.g. adding `:available`) makes Oban warn that incomplete states are
    # missing, which `--warnings-as-errors` turns into a build failure.
    # Concurrency is capped at 1 by the queue, so parallel *execution* is
    # impossible; delete_queued_jobs/0 prevents parallel *chains*.
    unique: [period: 10, states: [:scheduled]]

  require Logger

  import Ecto.Query

  alias PhoenixKit.Email.SendProfile
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSProcessor

  @default_long_poll_timeout 20

  # Back-off interval used when the config is (recoverably) invalid, so a
  # misconfigured system is not polled at the full rate while it keeps failing.
  @misconfig_backoff_ms 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Check if polling is enabled before processing
    if should_poll?() do
      Logger.debug("SQS Polling Job: Starting polling cycle")

      config = Emails.get_sqs_config()

      # The self-scheduling chain owns continuation; the poll interval IS the
      # retry cadence. We ALWAYS schedule the next cycle while polling is enabled
      # and return :ok — never {:error}. Returning {:error} would either spawn a
      # duplicate chain (Oban retry + self-schedule both firing) or, once the 3
      # Oban attempts are exhausted on a sustained outage, let the chain die
      # permanently until an app restart. A transient receive error simply
      # retries on the next scheduled poll; a recoverable misconfiguration backs
      # off but keeps the chain alive so it resumes once fixed.
      # delete_queued_jobs/0 in schedule_next_poll keeps this to exactly one chain.
      next_interval =
        case validate_configuration(config) do
          :ok ->
            log_cycle_result(perform_polling_cycle(config))
            config.polling_interval_ms

          {:error, reason} ->
            Logger.error("SQS Polling Job: Invalid configuration - #{reason}")
            @misconfig_backoff_ms
        end

      schedule_next_poll(next_interval)
      :ok
    else
      Logger.debug("SQS Polling Job: Polling disabled, skipping cycle")
      :ok
    end
  end

  # A failed polling cycle does not fail the Oban job (the chain self-continues);
  # we log it loudly so a sustained outage stays observable.
  defp log_cycle_result({:ok, _}), do: :ok

  defp log_cycle_result({:error, reason}) do
    Logger.error("SQS Polling Job: Polling cycle failed", %{reason: inspect(reason)})
    :ok
  end

  @doc """
  Cancels all scheduled SQS polling jobs.

  Called when polling is disabled to immediately clean up pending jobs.

  ## Returns

  - `{:ok, count}` - Number of cancelled jobs

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingJob.cancel_scheduled()
      {:ok, 2}
  """
  @spec cancel_scheduled() :: {:ok, non_neg_integer()}
  def cancel_scheduled do
    {count, _} = delete_queued_jobs()
    Logger.info("SQSPollingJob: Cancelled #{count} scheduled jobs")
    {:ok, count}
  end

  @doc """
  Returns the Oban `worker` column value for this job.

  Single source of truth for callers that query `Oban.Job` by worker name
  (e.g. `SQSPollingManager`), so they never drift from `inspect(__MODULE__)`.
  """
  @spec worker_name() :: String.t()
  def worker_name, do: inspect(__MODULE__)

  # Delete all queued (not-yet-running) polling jobs. Does NOT touch an
  # :executing job, so the running cycle is never interrupted. Returns the
  # Repo.delete_all/1 {count, _} tuple.
  defp delete_queued_jobs do
    worker = worker_name()

    Oban.Job
    |> where([j], j.worker == ^worker)
    |> where([j], j.state in ["available", "scheduled"])
    |> get_repo().delete_all()
  end

  defp get_repo do
    PhoenixKit.RepoHelper.repo()
  end

  ## --- Private Functions ---

  @doc false
  # Check if polling should be performed. Not `defp` so the sender-aware
  # gate can be unit-tested directly without a real SQS/network round
  # trip — same rationale as `BrevoPollingJob`'s and `DeliveryWorker`'s
  # internal seams.
  def should_poll? do
    Emails.enabled?() and
      Emails.ses_events_enabled?() and
      Emails.sqs_polling_enabled?() and
      ses_actively_configured?()
  end

  # Sender-aware gate, mirroring the (parallel) Brevo poller design — see
  # PR #18 (BrevoPollingJob isn't on main yet, so there's nothing to
  # literally reference here). SQS credentials being *reachable* isn't
  # the same as SES actually being the thing sending mail right now. Two
  # ways to count as "actively configured":
  #
  #   - `Emails.aws_configured?/0` — the explicit override: SQS polling
  #     predates the SendProfile system, and plenty of deployments still
  #     configure SES directly (legacy `aws_access_key_id`/
  #     `aws_secret_access_key` Settings, env vars, or a bare `aws_ses`
  #     Integrations connection with no SendProfile pointed at it at
  #     all). Requiring a SendProfile unconditionally would silently stop
  #     polling for every one of those pre-existing setups. Checked
  #     first — it's the cached lookup (`PhoenixKit.Cache`-backed, see
  #     `Emails.aws_ses_credentials/0`), cheaper than the DB round trip
  #     below.
  #   - an enabled SendProfile pointed at an `"aws_ses"` integration (the
  #     current, profile-based way to wire up a sender).
  defp ses_actively_configured? do
    Emails.aws_configured?() or has_enabled_ses_send_profile?()
  end

  defp has_enabled_ses_send_profile? do
    SendProfile
    |> where([sp], sp.enabled == true and sp.provider_kind == "aws_ses")
    |> limit(1)
    |> get_repo().exists?()
  end

  # Validate SQS configuration
  defp validate_configuration(config) do
    cond do
      is_nil(config.queue_url) or config.queue_url == "" ->
        {:error, "SQS queue URL not configured"}

      not is_integer(config.polling_interval_ms) or config.polling_interval_ms < 1000 ->
        # Sub-second intervals round down to schedule_in: 0 (Oban schedules in
        # whole seconds), causing a back-to-back poll loop. Mirror
        # SQSPollingManager.set_polling_interval/1's >= 1000 guard.
        {:error, "Invalid polling interval (must be >= 1000ms)"}

      not is_integer(config.max_messages_per_poll) or
        config.max_messages_per_poll <= 0 or
          config.max_messages_per_poll > 10 ->
        {:error, "Invalid max messages per poll (must be 1-10)"}

      not is_integer(config.visibility_timeout) or config.visibility_timeout <= 0 ->
        {:error, "Invalid visibility timeout"}

      true ->
        :ok
    end
  end

  # Perform one polling cycle
  defp perform_polling_cycle(config) do
    _start_time = System.monotonic_time(:millisecond)

    case receive_messages(config) do
      {:ok, [_ | _] = messages} ->
        Logger.info("SQS Polling Job: Received #{length(messages)} messages")

        processing_start = System.monotonic_time(:millisecond)
        processed_count = process_messages(messages, config)
        processing_time = System.monotonic_time(:millisecond) - processing_start

        Logger.info(
          "SQS Polling Job: Processed #{processed_count}/#{length(messages)} messages in #{processing_time}ms"
        )

        {:ok,
         %{processed: processed_count, total: length(messages), duration_ms: processing_time}}

      {:ok, []} ->
        Logger.debug("SQS Polling Job: No messages in queue")
        {:ok, %{processed: 0, total: 0}}

      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to receive messages", %{
          reason: inspect(reason),
          queue_url: config.queue_url
        })

        {:error, reason}
    end
  end

  # Receive messages from SQS queue
  defp receive_messages(config) do
    aws_config = build_aws_config(config)

    request =
      ExAws.SQS.receive_message(
        config.queue_url,
        max_number_of_messages: config.max_messages_per_poll,
        wait_time_seconds: @default_long_poll_timeout,
        visibility_timeout: config.visibility_timeout,
        message_attribute_names: [:all],
        attribute_names: [:all]
      )

    case ExAws.request(request, aws_config) do
      {:ok, %{"Messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{"messages" => messages}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{messages: messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"Messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, %{body: %{"messages" => messages}}} when is_list(messages) ->
        {:ok, messages}

      {:ok, _response} ->
        {:ok, []}

      {:error, error} ->
        Logger.error("SQS Polling Job: ExAws request failed", %{
          error: inspect(error),
          queue_url: config.queue_url
        })

        {:error, error}
    end
  end

  # Process message list in parallel
  defp process_messages(messages, config) do
    aws_config = build_aws_config(config)

    tasks =
      Enum.map(messages, fn message ->
        Task.async(fn ->
          process_single_message(message, config.queue_url, aws_config)
        end)
      end)

    # yield_many (not await_many) so a slow task can't RAISE and abort the whole
    # perform/1: a raised timeout would trigger an Oban retry and tear down the
    # in-flight delete_message calls, re-cycling messages. Tasks that yield
    # {:ok, true} count as processed; un-yielded/timed-out ones are shut down and
    # treated as not-processed, so their messages simply re-receive normally
    # after the SQS visibility timeout.
    tasks
    |> Task.yield_many(30_000)
    |> Enum.count(fn {task, result} ->
      case result || Task.shutdown(task, :brutal_kill) do
        {:ok, true} -> true
        _ -> false
      end
    end)
  end

  # Process a single message.
  #
  # ExAws.SQS may return messages with either string keys ("ReceiptHandle") or
  # atom keys (:receipt_handle, from the `%{body: %{messages: [...]}}` parsed
  # shape that receive_messages/1 also accepts). Read both, otherwise the
  # receipt handle comes back nil and delete_message/3 silently fails, leaving
  # the message to be re-received forever.
  defp process_single_message(message, queue_url, aws_config) do
    message_id = message["MessageId"] || message[:message_id]
    receipt_handle = message["ReceiptHandle"] || message[:receipt_handle]

    with {:ok, event_data} <- SQSProcessor.parse_sns_message(message),
         {:ok, _result} <- SQSProcessor.process_email_event(event_data),
         :ok <- delete_message(queue_url, receipt_handle, aws_config) do
      true
    else
      {:error, reason} ->
        Logger.error("SQS Polling Job: Failed to process message", %{
          message_id: message_id,
          reason: inspect(reason)
        })

        false
    end
  end

  # Delete processed message from queue. Returns the failure (instead of
  # swallowing it as :ok) so a message that wasn't actually deleted is not
  # counted as processed — the silent :ok previously hid a nil-receipt-handle
  # bug that made messages re-cycle forever.
  defp delete_message(_queue_url, nil, _aws_config) do
    Logger.error("SQS Polling Job: Missing receipt handle, cannot delete message")
    {:error, :missing_receipt_handle}
  end

  defp delete_message(queue_url, receipt_handle, aws_config) do
    ExAws.SQS.delete_message(queue_url, receipt_handle)
    |> ExAws.request(aws_config)
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("SQS Polling Job: Failed to delete message", %{
          error: inspect(error),
          queue_url: queue_url
        })

        {:error, error}
    end
  end

  # Schedule next polling job
  defp schedule_next_poll(interval_ms) do
    if should_poll?() do
      # Guarantee exactly one queued future job. The `unique` window only
      # coalesces near-simultaneous inserts (within its period); but a
      # self-reschedule fires a full cycle later (long-poll up to 20s + the
      # interval) than an enable_polling insert, which is outside that window —
      # leaving two parallel chains that double SQS receive calls. Deleting any
      # already-queued job immediately before inserting collapses such a stale
      # duplicate into a single chain, independent of the operator-configurable
      # interval. The :executing job (this one) is untouched, and the `unique`
      # window still backstops the tiny delete-then-double-insert race.
      delete_queued_jobs()

      # Oban schedule_in is in whole SECONDS — div(interval_ms, 1000) is 0 for
      # any 1..999ms interval, which would queue the next poll immediately and
      # spin a back-to-back loop. Floor at 1s. (validate_configuration/1 already
      # rejects sub-second intervals; this is a defensive backstop.)
      %{}
      |> __MODULE__.new(schedule_in: max(div(interval_ms, 1000), 1))
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Logger.debug("SQS Polling Job: Next poll scheduled in #{interval_ms}ms")
          :ok

        {:error, reason} ->
          Logger.error("SQS Polling Job: Failed to schedule next poll", %{
            reason: inspect(reason)
          })

          :ok
      end
    else
      Logger.debug("SQS Polling Job: Polling disabled, not scheduling next poll")
      :ok
    end
  end

  # Build AWS configuration
  defp build_aws_config(config) do
    if is_binary(config.aws_access_key_id) and config.aws_access_key_id != "" and
         is_binary(config.aws_secret_access_key) and config.aws_secret_access_key != "" and
         is_binary(config.aws_region) and config.aws_region != "" do
      [
        access_key_id: String.trim(config.aws_access_key_id),
        secret_access_key: String.trim(config.aws_secret_access_key),
        region: String.trim(config.aws_region)
      ]
    else
      []
    end
  end
end
