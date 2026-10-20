defmodule PhoenixKit.Modules.Emails.Verification.BatchStartWorker do
  @moduledoc """
  Lays a batch out: enqueues one `VerifyEmailWorker` per pending item
  (`Batches.lay_out/1`). The items were inserted when the batch was started, so the
  args carry the batch uuid and nothing else - no personal data lands in `oban_jobs`.

  A job from an earlier version has the address list in its args (`"emails"`) and the
  batch has no items yet: `Batches.lay_out/2` inserts them, and the list is removed
  from the job's args once it has been used.

  Runs on the `:email_verification` queue, which the host's Oban config must
  declare (see `PhoenixKit.Modules.Emails.Verification.queue_configured?/0`).
  Running it again is harmless: only the items still pending and without a job get one.
  If the last attempt fails too the batch is cancelled: its verify jobs could not be
  enqueued, so it could never finish.
  """

  use Oban.Worker, queue: :email_verification, max_attempts: 3

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_uuid" => uuid} = args} = job) when is_binary(uuid) do
    case Batches.get(uuid) do
      nil -> {:cancel, :batch_not_found}
      %Batch{state: "cancelled"} -> {:cancel, :batch_cancelled}
      %Batch{state: "done"} -> :ok
      %Batch{} = batch -> lay_out(batch, args, job)
    end
  rescue
    error ->
      give_up_on_last_attempt(job, error)
      reraise error, __STACKTRACE__
  end

  def perform(%Oban.Job{}), do: {:cancel, :malformed_args}

  defp lay_out(batch, %{"emails" => emails}, job) when is_list(emails) do
    :ok = Batches.lay_out(batch, emails)
    forget_addresses(job)
  end

  defp lay_out(batch, _args, _job), do: Batches.lay_out(batch)

  # The list has done its work; the job row (and its history) need not keep it.
  defp forget_addresses(%Oban.Job{id: id}) when is_integer(id) do
    from(j in Oban.Job,
      where: j.id == ^id,
      update: [set: [args: fragment("? - 'emails'", j.args)]]
    )
    |> PhoenixKit.RepoHelper.repo().update_all([], prefix: Oban.config().prefix)

    :ok
  rescue
    error ->
      Logger.warning(
        "[Emails.Verification] could not remove the address list from a start job: " <>
          Batches.mask_addresses(Exception.message(error))
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Emails.Verification] could not remove the address list from a start job: " <>
          Batches.mask_addresses(inspect(reason))
      )

      :ok
  end

  defp forget_addresses(_job), do: :ok

  defp give_up_on_last_attempt(%Oban.Job{attempt: attempt, max_attempts: max} = job, error)
       when attempt >= max do
    uuid = job.args["batch_uuid"]

    Logger.error(
      "[Emails.Verification] batch #{uuid} could not be laid out, cancelling it: " <>
        Batches.mask_addresses(Exception.message(error))
    )

    Batches.abandon(uuid)
  rescue
    _ -> :ok
  end

  defp give_up_on_last_attempt(_job, _error), do: :ok
end
