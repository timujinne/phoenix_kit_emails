defmodule PhoenixKit.Modules.Emails.Verification.BatchStartWorker do
  @moduledoc """
  Lays a batch out: inserts its items and enqueues one `VerifyEmailWorker` per
  address (`Batches.lay_out/2`).

  Runs on the `:email_verification` queue, which the host's Oban config must
  declare (see `PhoenixKit.Modules.Emails.Verification.queue_configured?/0`).
  Running it again is harmless: items already there are kept, and only the ones
  still pending get a job.
  """

  use Oban.Worker, queue: :email_verification, max_attempts: 3

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_uuid" => uuid, "emails" => emails}})
      when is_list(emails) do
    case Batches.get(uuid) do
      nil -> {:cancel, :batch_not_found}
      %Batch{state: "cancelled"} -> {:cancel, :batch_cancelled}
      %Batch{state: "done"} -> :ok
      %Batch{} = batch -> Batches.lay_out(batch, emails)
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :malformed_args}
end
