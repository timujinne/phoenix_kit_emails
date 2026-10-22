defmodule PhoenixKit.Modules.Emails.Verification.QueueSweepWorker do
  @moduledoc """
  The Oban job that keeps the SMTP queue from holding work nobody will finish, on the
  queue `:email_verification`. It needs no runner: a runner that is gone, a closed
  port 25 or a paused runner must not leave addresses (and the batches waiting for them)
  queued for ever.

  Each run:

    * with the SMTP mode `off`, settles what is still queued (`SmtpQueue.drain_disabled/0`)
      - otherwise, in this order,
    * takes back the leases that ran out (`SmtpQueue.expire_leases/0`),
    * gives up the addresses older than `email_verify_smtp_queue_max_age_h`
      (`SmtpQueue.expire_stale/0`),
    * finishes the batch items that wait for an address the queue no longer holds
      (`SmtpQueue.repair_stranded/0`).

  Then it puts its successor on the queue and ends, while addresses are queued or leased
  or batch items wait for the SMTP result. An empty queue ends the chain, and the next
  queued address starts it again (`schedule/1`, like `LocalRunnerWorker`). A host may also
  list the worker in its Oban crontab; a run that finds a job waiting adds nothing.

  A sweep that raises is logged and does not end the chain: the successor is put on the
  queue all the same.
  """

  use Oban.Worker, queue: :email_verification, max_attempts: 3

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue

  @interval_s 600
  @unique [period: :infinity, states: [:available, :scheduled, :retryable]]

  @doc "The seconds between two runs of the chain."
  @spec interval_s() :: pos_integer()
  def interval_s, do: @interval_s

  @doc """
  Puts the job on the queue to run in `delay_s` seconds, unless one is waiting already.
  Never raises (a host without the queue or without Oban just gets `:ok`).
  """
  @spec schedule(non_neg_integer()) :: :ok
  def schedule(delay_s \\ @interval_s) do
    %{} |> new(schedule_in: delay_s, unique: @unique) |> Oban.insert()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if sweep_failed?() or work_left_or_unknown?(), do: schedule(), else: :ok
  end

  @doc false
  @spec sweep() :: :ok
  def sweep do
    if Config.smtp_mode() == "off" do
      SmtpQueue.drain_disabled()
    else
      SmtpQueue.expire_leases()
      SmtpQueue.expire_stale()
    end

    SmtpQueue.repair_stranded()
    :ok
  end

  # A sweep that raised (the database was away for a moment) must not end the chain:
  # nothing would start it again until a new address is queued. The job still ends `:ok`,
  # so Oban does not retry it on top of the successor; the unique insert keeps one job.
  defp sweep_failed? do
    sweep()
    false
  rescue
    error ->
      Logger.error(
        "[Emails.Verification] the SMTP queue sweep failed: " <> Exception.message(error)
      )

      true
  end

  defp work_left_or_unknown? do
    work_left?()
  rescue
    _ -> true
  end

  defp work_left? do
    counts = SmtpQueue.counts()

    counts.queued + counts.leased > 0 or
      repo().exists?(
        from(i in BatchItem,
          join: b in Batch,
          on: b.uuid == i.batch_uuid and b.state in ["queued", "running"],
          where: i.state == "awaiting_smtp"
        )
      )
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
