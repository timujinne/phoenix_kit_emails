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

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.SQSPollingJob

  @doc """
  Enables SQS polling by setting the configuration and starting the first job.

  ## Returns

  - `{:ok, job}` - Successfully enabled and started first job
  - `{:error, reason}` - Failed to enable polling

  ## Examples

      iex> PhoenixKit.Modules.Emails.SQSPollingManager.enable_polling()
      {:ok, %Oban.Job{id: 1, queue: "sqs_polling"}}
  """
  def enable_polling do
    Logger.info("SQS Polling Manager: Enabling polling")

    # Clear any queued next-poll first, then start exactly one fresh job. This
    # GUARANTEES a live polling chain on enable (critical for the off→on UI
    # toggle). If a job is still executing, its end-of-cycle schedule_next_poll
    # deletes this freshly-inserted job before inserting its own, collapsing the
    # two into a single chain (see SQSPollingJob.schedule_next_poll/1). (A guard
    # that skipped the insert when a job was already executing would leave no
    # chain if that job finished its cycle while disabled.)
    SQSPollingJob.cancel_scheduled()

    with {:ok, _setting} <- Emails.set_sqs_polling(true),
         {:ok, job} <- insert_poll_job() do
      Logger.info("SQS Polling Manager: Polling enabled and first job started")
      {:ok, job}
    else
      {:error, reason} = error ->
        Logger.error("SQS Polling Manager: Failed to enable polling", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Disables SQS polling by updating the configuration.

  Note: Existing scheduled jobs will check this setting and skip execution.

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
        # Cancel any scheduled polling jobs
        SQSPollingJob.cancel_scheduled()
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

    case insert_poll_job() do
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

  # Insert an immediately-available polling job. Used both to start the chain on
  # enable_polling/0 and to force an out-of-schedule poll via poll_now/0.
  defp insert_poll_job do
    %{}
    |> SQSPollingJob.new()
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
