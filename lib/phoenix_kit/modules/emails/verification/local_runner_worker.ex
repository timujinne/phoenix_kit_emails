defmodule PhoenixKit.Modules.Emails.Verification.LocalRunnerWorker do
  @moduledoc """
  The Oban job behind the built-in runner (`Verification.LocalRunner`, SMTP mode
  `local`), on the queue `:email_verification`.

  Each run is one `LocalRunner.cycle/1`. Then the job puts its successor on the queue and
  ends - while the mode is `local` and addresses are queued or leased. With an empty queue
  the chain ends, and `LocalRunner.wake/0` starts it again when an address is queued (and
  `LocalRunner.activate/0` when the mode is switched to `local`). A mode other than
  `local` ends the chain at its next run.

  At most one job waits (`unique` over the states `available`, `scheduled`, `retryable`,
  for ever): a wake while a job is waiting adds nothing, and a wake during a cycle adds the
  job that runs next. Two cycles overlapping are safe all the same: the queue hands out
  each address once, and the runner's concurrency is counted from the queue before each
  claim (so an overlap may briefly exceed the limit, never hand out an address twice).

  A cycle that fails (the database, a bug) is logged and the chain goes on, so one bad
  moment does not stop the checks. A node killed in the middle of a cycle leaves its job
  `executing` until the host's Oban rescues it (the Lifeline plugin); the next queued
  address starts the chain meanwhile.
  """

  use Oban.Worker, queue: :email_verification, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.LocalRunner

  @unique [period: :infinity, states: [:available, :scheduled, :retryable]]

  @doc """
  Puts the job on the queue to run in `delay_s` seconds, unless one is waiting already.
  Never raises (a host without the queue or without Oban just gets `:ok`).
  """
  @spec schedule(non_neg_integer()) :: :ok
  def schedule(delay_s) do
    %{} |> new(schedule_in: delay_s, unique: @unique) |> Oban.insert()
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case cycle() do
      :stopped -> :ok
      {:ok, result} -> continue(result)
      :failed -> schedule(Config.idle_poll_s())
    end
  end

  defp cycle do
    case LocalRunner.cycle() do
      :stopped -> :stopped
      result -> {:ok, result}
    end
  rescue
    error ->
      Logger.error(
        "[Emails.Verification] a cycle of the built-in SMTP runner failed: " <>
          Batches.mask_addresses(Exception.message(error))
      )

      :failed
  end

  defp continue(result) do
    case LocalRunner.next_delay(result) do
      :stop -> :ok
      seconds -> schedule(seconds)
    end
  end
end
