defmodule PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker do
  @moduledoc """
  Verifies one address of a batch and counts it.

  `Verification.verify/2` does the work - a fresh stored verdict is reused, the
  pipeline runs otherwise. Then, in one transaction, the item is marked done and
  the batch's counters move (`Batches.record_result/3`); when that was the last
  address the batch becomes `"done"`. Progress goes out on the batch's PubSub
  topic.

  ## Retries

  ## SMTP

  With the SMTP mode on (`email_verify_smtp_mode`), an address that passes the MX
  step is queued for an SMTP session (`Verification.verify(email, smtp: :enqueue)`)
  and the job does not count it: the item becomes `"awaiting_smtp"`
  (`Batches.await_smtp/2`) and the SMTP queue finishes it when the final verdict
  lands. The job is done; nothing waits for the runner here. If the batch was
  cancelled while the job ran, the queued row is cancelled too, unless another live
  batch needs the address.

  A `"temp"` verdict caused by a failed DNS lookup (`"dns_error"`) is put off with `{:snooze, seconds}` instead
  of being counted: see `Verification.Retry`. Snoozing does not use up an Oban
  attempt; the number of snoozes (`meta["snoozed"]`) is what the retry limit
  counts. Once the limit is reached the `"temp"` verdict is kept and counted.
  `max_attempts` covers real failures only (the database, a crash). When the last
  one fails too, the address is counted as `"temp"` (`Batches.give_up/2`) before
  the error goes back to Oban, so the batch still reaches `processed == total`.
  A `"temp"` verdict is stored for such an address as well (reason `"job_failed"`,
  or the reason of the `"temp"` verdict it already had, e.g. `"dns_error"`), so
  that `Verification.summary/1` agrees with the batch's counts.

  The job's args are the batch uuid and the item uuid; the address is read from the
  item, so it never lands in `oban_jobs`. A job from an earlier version has the address
  itself (`"email"`) and is still accepted.

  At most one job per batch and item exists at a time (`unique` on both args,
  across every incomplete state).
  """

  use Oban.Worker,
    queue: :email_verification,
    max_attempts: 3,
    unique: [keys: [:batch_uuid, :item_uuid], period: :infinity, states: :incomplete]

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.Retry
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_uuid" => batch_uuid}} = job) do
    case member(job.args) do
      nil -> {:cancel, :not_a_member}
      {email, item} -> batch_uuid |> run(email, item, job) |> settle(job, batch_uuid, email)
    end
  rescue
    error ->
      settle({:error, error}, job, job.args["batch_uuid"], rescue_address(job.args))
      reraise error, __STACKTRACE__
  end

  def perform(%Oban.Job{}), do: {:cancel, :malformed_args}

  # What the job is about: the address with the item it was read from, or - in the
  # shape of an earlier version, which carries the address itself - the address alone
  # (the item is looked up by it later). A job with neither is malformed.
  defp member(%{"batch_uuid" => batch_uuid, "item_uuid" => item_uuid}) do
    case Batches.get_item_by_uuid(batch_uuid, item_uuid) do
      %BatchItem{email: email} = item -> {email, item}
      nil -> nil
    end
  end

  defp member(%{"email" => email}) when is_binary(email), do: {email, nil}
  defp member(_args), do: nil

  # A crash in the lookup itself leaves nothing to count.
  defp rescue_address(args) do
    case member(args) do
      {email, _item} -> email
      nil -> nil
    end
  rescue
    _ -> nil
  end

  defp run(batch_uuid, email, item, job) do
    with {:ok, _batch} <- open_batch(batch_uuid),
         {:ok, _item} <- pending_item(batch_uuid, email, item),
         {:ok, result} <- Verification.verify(email, smtp: :enqueue) do
      case Retry.decide(result, snoozed(job)) do
        {:snooze, seconds} ->
          Batches.schedule_retry(batch_uuid, email, seconds)
          {:snooze, seconds}

        :done when result.reason == "smtp_pending" ->
          await(batch_uuid, email)

        :done ->
          finish(batch_uuid, email, result.status)
      end
    else
      :finished -> :ok
      {:cancel, _reason} = cancel -> cancel
      {:error, _reason} = error -> error
    end
  end

  # A failure on the last attempt will not be retried: count the address now.
  defp settle({:error, _reason} = error, %Oban.Job{} = job, batch_uuid, email) do
    if job.attempt >= job.max_attempts and is_binary(email),
      do: Batches.give_up(batch_uuid, email)

    error
  end

  defp settle(outcome, _job, _batch_uuid, _email), do: outcome

  defp open_batch(batch_uuid) do
    case Batches.get(batch_uuid) do
      nil -> {:cancel, :batch_not_found}
      %Batch{state: "cancelled"} -> {:cancel, :batch_cancelled}
      %Batch{state: "done"} -> :finished
      %Batch{} = batch -> {:ok, batch}
    end
  end

  defp pending_item(batch_uuid, email, nil),
    do: batch_uuid |> Batches.get_item(email) |> check_item()

  defp pending_item(_batch_uuid, _email, %BatchItem{} = item), do: check_item(item)

  defp check_item(nil), do: {:cancel, :not_a_member}

  defp check_item(%BatchItem{state: state}) when state in ["done", "awaiting_smtp"],
    do: :finished

  defp check_item(%BatchItem{} = item), do: {:ok, item}

  defp await(batch_uuid, email) do
    case Batches.await_smtp(batch_uuid, email) do
      {:ok, _awaiting_or_settled} -> :ok
      {:error, :already_done} -> :ok
      {:error, :batch_closed} -> release_queued(email)
    end
  end

  # The batch was cancelled after this job queued the address: nobody is waiting for
  # the session any more (unless another live batch is).
  defp release_queued(email) do
    SmtpQueue.cancel_unneeded(email)
    {:cancel, :batch_cancelled}
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
