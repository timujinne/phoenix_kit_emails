defmodule PhoenixKit.Modules.Emails.BrevoPollingManager do
  @moduledoc """
  Manager module for Brevo event polling via Oban jobs.

  Mirrors `SQSPollingManager` — see that module's `@moduledoc` for the
  general architecture (Oban jobs instead of a GenServer, so settings
  changes take effect without a restart). `enable_polling/0` and
  `disable_polling/0` back the admin UI toggle; `poll_now/0` forces an
  immediate cycle regardless of the sender-aware gate (useful to verify a
  freshly-configured Brevo profile before waiting for the next scheduled
  tick — the job itself still no-ops safely if the gate isn't satisfied).
  """

  require Logger

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Modules.Emails.BrevoPollingJob

  @doc """
  Enables Brevo event polling by setting the configuration and starting
  the first job.
  """
  def enable_polling do
    Logger.info("Brevo Polling Manager: Enabling polling")

    BrevoPollingJob.cancel_scheduled()

    with {:ok, _setting} <- Emails.set_brevo_events_enabled(true),
         {:ok, job} <- insert_poll_job() do
      Logger.info("Brevo Polling Manager: Polling enabled and first job started")
      {:ok, job}
    else
      {:error, reason} = error ->
        Logger.error("Brevo Polling Manager: Failed to enable polling", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Disables Brevo event polling by updating the configuration and
  cancelling scheduled jobs.
  """
  def disable_polling do
    Logger.info("Brevo Polling Manager: Disabling polling")

    case Emails.set_brevo_events_enabled(false) do
      {:ok, _setting} ->
        BrevoPollingJob.cancel_scheduled()
        Logger.info("Brevo Polling Manager: Polling disabled")
        :ok

      {:error, reason} ->
        Logger.error("Brevo Polling Manager: Failed to disable polling", %{
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @doc """
  Sets the polling interval in milliseconds (minimum 30 000ms).
  """
  def set_polling_interval(interval_ms) when is_integer(interval_ms) and interval_ms >= 30_000 do
    Logger.info("Brevo Polling Manager: Setting polling interval to #{interval_ms}ms")
    Emails.set_brevo_polling_interval(interval_ms)
  end

  def set_polling_interval(interval_ms) do
    {:error, "Invalid interval: #{interval_ms}. Must be >= 30000ms"}
  end

  @doc """
  Triggers an immediate polling job, regardless of the normal schedule.
  """
  def poll_now do
    Logger.info("Brevo Polling Manager: Triggering immediate poll")

    unless polling_enabled?() do
      Logger.warning("Brevo Polling Manager: Polling is disabled, but executing manual poll")
    end

    case insert_poll_job() do
      {:ok, job} ->
        Logger.info("Brevo Polling Manager: Immediate poll job created", %{job_id: job.id})
        {:ok, job}

      {:error, reason} = error ->
        Logger.error("Brevo Polling Manager: Failed to create immediate poll job", %{
          reason: inspect(reason)
        })

        error
    end
  end

  @doc """
  Returns the current status of Brevo event polling.

  `active_brevo_profiles` is the sender-aware gate's own count (see
  `BrevoPollingJob`'s moduledoc): the number of *enabled* send profiles
  pointed at a `"brevo_api"` integration. When it's 0, the polling chain
  is alive (as long as `enabled` is true) but every cycle no-ops.
  """
  def status do
    %{
      enabled: Emails.brevo_events_enabled?(),
      interval_ms: Emails.get_brevo_polling_interval(),
      pending_jobs: count_pending_jobs(),
      last_polled_at: Emails.get_brevo_last_polled_at(),
      system_enabled: Emails.enabled?(),
      active_brevo_profiles: count_active_brevo_profiles()
    }
  end

  ## --- Private Functions ---

  defp insert_poll_job do
    %{}
    |> BrevoPollingJob.new()
    |> Oban.insert()
  end

  defp polling_enabled? do
    Emails.brevo_events_enabled?()
  end

  defp count_active_brevo_profiles do
    SendProfiles.list_send_profiles()
    |> Enum.count(&(&1.enabled and &1.provider_kind == "brevo_api"))
  end

  defp count_pending_jobs do
    repo = PhoenixKit.RepoHelper.repo()

    import Ecto.Query

    worker = BrevoPollingJob.worker_name()

    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ["available", "scheduled", "executing"],
      select: count(j.id)
    )
    |> repo.one()
  rescue
    _ -> 0
  end
end
