defmodule PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker do
  @moduledoc """
  Verifies one address of a batch and counts it.

  `Verification.verify/2` does the work - a fresh stored verdict is reused, the
  pipeline runs otherwise. Then, in one transaction, the item is marked done and
  the batch's counters move (`Batches.record_result/3`); when that was the last
  address the batch becomes `"done"`. Progress goes out on the batch's PubSub
  topic.

  ## Retries

  A `"temp"` verdict caused by a failed DNS lookup (`"dns_error"`), or by greylisting
  (only an SMTP result can say that), is put off with `{:snooze, seconds}` instead
  of being counted: see `Verification.Retry`. Snoozing does not use up an Oban
  attempt; the number of snoozes (`meta["snoozed"]`) is what the retry limit
  counts. Once the limit is reached the `"temp"` verdict is kept and counted.
  `max_attempts` covers real failures only (the database, a crash).

  At most one job per batch and address exists at a time (`unique` on both args,
  across every incomplete state).
  """

  use Oban.Worker,
    queue: :email_verification,
    max_attempts: 3,
    unique: [keys: [:batch_uuid, :email], period: :infinity, states: :incomplete]

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Retry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_uuid" => batch_uuid, "email" => email}} = job) do
    with {:ok, _batch} <- open_batch(batch_uuid),
         {:ok, _item} <- pending_item(batch_uuid, email),
         {:ok, result} <- Verification.verify(email) do
      case Retry.decide(result, snoozed(job)) do
        {:snooze, seconds} ->
          Batches.schedule_retry(batch_uuid, email, seconds)
          {:snooze, seconds}

        :done ->
          finish(batch_uuid, email, result.status)
      end
    else
      :finished -> :ok
      {:cancel, _reason} = cancel -> cancel
      {:error, _reason} = error -> error
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :malformed_args}

  defp open_batch(batch_uuid) do
    case Batches.get(batch_uuid) do
      nil -> {:cancel, :batch_not_found}
      %Batch{state: "cancelled"} -> {:cancel, :batch_cancelled}
      %Batch{state: "done"} -> :finished
      %Batch{} = batch -> {:ok, batch}
    end
  end

  defp pending_item(batch_uuid, email) do
    case Batches.get_item(batch_uuid, email) do
      nil -> {:cancel, :not_a_member}
      %BatchItem{state: "done"} -> :finished
      %BatchItem{} = item -> {:ok, item}
    end
  end

  defp finish(batch_uuid, email, status) do
    case Batches.record_result(batch_uuid, email, status) do
      {:ok, _batch} -> :ok
      {:error, :already_done} -> :ok
      {:error, :batch_closed} -> {:cancel, :batch_cancelled}
    end
  end

  defp snoozed(%Oban.Job{meta: %{"snoozed" => snoozed}}) when is_integer(snoozed), do: snoozed
  defp snoozed(%Oban.Job{}), do: 0
end
