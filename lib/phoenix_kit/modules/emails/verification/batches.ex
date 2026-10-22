defmodule PhoenixKit.Modules.Emails.Verification.Batches do
  @moduledoc """
  Batches of addresses to verify: creating them, laying out their items, counting
  results into them, cancelling them. Callers use the delegating functions of
  `PhoenixKit.Modules.Emails.Verification`; the workers use the rest.

  ## Life of a batch

    1. `start/4` normalises and deduplicates the addresses, stores the batch
       (`"queued"`), lays its items out (one row per address, inserted in chunks;
       `total` is the number of items) and enqueues a `BatchStartWorker` that
       carries nothing but the batch uuid - all in one transaction, so there is
       no batch without its items and its job. The addresses live in the items
       table only, never in `oban_jobs`.
    2. `BatchStartWorker` calls `lay_out/1`: the batch becomes `"running"`, and
       one `VerifyEmailWorker` job (batch uuid and item uuid) is enqueued per
       pending item.
    3. Each `VerifyEmailWorker` ends with `record_result/3`, which marks its item
       done and counts it into the batch in one transaction. The counters move in
       SQL (`processed + 1`, the status's entry in `counts`), so concurrent jobs
       never lose an update. The job that makes `processed == total` also
       makes the batch `"done"`.
    4. With SMTP on, an address that passed the MX step is not finished by its job:
       `await_smtp/2` moves its item to `"awaiting_smtp"` (counted in the batch's
       `awaiting_smtp`, not in `processed`) and the SMTP queue finishes it later with
       `settle_awaiting/2`, when the final verdict lands. The batch is `"done"` only
       when every item has finished SMTP.

  Every change is broadcast on `batch_topic/1` as
  `{:email_verify_batch, %{uuid:, state:, processed:, total:, counts:}}`. The
  message carries the row as it is when it is sent, but workers run in parallel and
  messages from different workers can still arrive out of order: a consumer must
  ignore a snapshot whose `processed` is lower than the one it holds (or re-read the
  batch on every message). The batch's final message has state `"done"` or
  `"cancelled"`.

  A batch holds at most `max_size/0` distinct addresses.

  Jobs enqueued by an earlier version carry the addresses in their args
  (`BatchStartWorker` with `"emails"`, `VerifyEmailWorker` with `"email"`); both workers
  still accept that shape (`lay_out/2`) so that nothing already queued is lost. The
  other direction does not hold: a node still on the old code cancels a job of this
  version as malformed, so a rolling deploy should drain the queue first. Oban also
  keeps the text of a job's errors, and a database error can quote a row: keep the
  `errors` of `oban_jobs` out of anywhere they should not reach.
  """

  import Ecto.Query
  require Logger

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.BatchStartWorker
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue
  alias PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @item_chunk 1_000
  @job_chunk 500
  @max_size 100_000

  @type snapshot :: %{
          uuid: String.t(),
          state: String.t(),
          processed: non_neg_integer(),
          total: non_neg_integer(),
          counts: %{String.t() => non_neg_integer()},
          awaiting_smtp: non_neg_integer()
        }

  ## --- Creating ---

  @doc "The most distinct addresses one batch can hold."
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @spec start([term()], String.t(), term(), keyword()) ::
          {:ok, Batch.t()}
          | {:error, :no_emails | :too_many_emails | Ecto.Changeset.t() | term()}
  def start(emails, source_type, source_ref, opts) do
    case dedup(emails) do
      [] ->
        {:error, :no_emails}

      keys when length(keys) > @max_size ->
        {:error, :too_many_emails}

      keys ->
        changeset =
          Batch.create_changeset(%Batch{}, %{
            source_type: source_type,
            source_ref: ref(source_ref),
            title: Keyword.get(opts, :title),
            created_by_uuid: Keyword.get(opts, :created_by_uuid),
            total: length(keys)
          })

        if changeset.valid?, do: insert_with_job(changeset, keys), else: {:error, changeset}
    end
  end

  # Whatever goes wrong - the database, no Oban instance running - the caller gets
  # an error tuple, and the transaction leaves no batch behind.
  # No deadline: the whole transaction shares one, and laying out 100,000 items can
  # take longer than the pool's default 15 s on a slow or busy database. Each query
  # still has its own.
  defp insert_with_job(changeset, keys) do
    repo().transaction(
      fn ->
        with {:ok, batch} <- repo().insert(changeset),
             :ok <- insert_items(batch.uuid, keys),
             batch = %{batch | total: sync_total(batch.uuid, UtilsDate.utc_now())},
             {:ok, _job} <- enqueue_start(batch) do
          batch
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end,
      timeout: :infinity
    )
  rescue
    error ->
      warn_start_failed(Exception.message(error))
      {:error, error}
  catch
    :exit, reason ->
      warn_start_failed(inspect(reason))
      {:error, reason}
  end

  @doc false
  # The text of a database or Oban failure may quote the rows it was writing, that is,
  # the addresses: they are masked like everywhere else in the logs.
  @spec warn_start_failed(String.t()) :: :ok
  def warn_start_failed(detail) do
    Logger.warning("[Emails.Verification] could not start a batch: " <> mask_addresses(detail))
  end

  defp enqueue_start(batch) do
    %{"batch_uuid" => batch.uuid}
    |> BatchStartWorker.new()
    |> Oban.insert()
  end

  # The same address twice - or with another case, which the case-insensitive
  # column would reject anyway - is one member. Input that cannot be stored
  # (blank, NUL, not text) is not a member at all.
  defp dedup(emails) do
    emails
    |> Enum.flat_map(fn email ->
      case Normalizer.storage_key(email) do
        nil -> []
        key -> [key]
      end
    end)
    |> Enum.uniq_by(&String.downcase/1)
  end

  # Anything else is passed on as it is: the changeset refuses it, and a read
  # for it finds nothing.
  defp ref(ref) when is_atom(ref) and not is_nil(ref), do: Atom.to_string(ref)
  defp ref(ref) when is_integer(ref), do: Integer.to_string(ref)
  defp ref(ref), do: ref

  ## --- Laying out (BatchStartWorker) ---

  @doc """
  Marks the batch running and enqueues a `VerifyEmailWorker` for every item that is
  still pending and has no job yet. Safe to run again after a partial failure.
  """
  @spec lay_out(Batch.t()) :: :ok
  def lay_out(%Batch{uuid: uuid}) do
    now = UtilsDate.utc_now()

    {started, _} =
      from(b in Batch, where: b.uuid == ^uuid and b.state == "queued")
      |> repo().update_all(set: [state: "running", started_at: now, updated_at: now])

    from(i in BatchItem,
      where: i.batch_uuid == ^uuid and i.state == "pending",
      select: {i.uuid, i.email}
    )
    |> repo().all()
    |> without_queued(uuid, started == 1)
    |> Enum.chunk_every(@job_chunk)
    |> Enum.each(fn chunk ->
      chunk
      |> Enum.map(fn {item_uuid, _email} ->
        VerifyEmailWorker.new(%{"batch_uuid" => uuid, "item_uuid" => item_uuid})
      end)
      |> Oban.insert_all()
    end)

    broadcast(uuid)
  end

  @doc """
  The way a `BatchStartWorker` job from an earlier version is laid out: its args carry
  the addresses, and the batch has no items yet. Inserts the items (the ones already
  there are left alone), sets `total` to the number of items, then goes on as
  `lay_out/1`.

  The items are the truth about who is in the batch: the case-insensitive column
  can merge addresses that `start/4` told apart, and `total` follows it - or
  `processed` could never reach it.
  """
  @spec lay_out(Batch.t(), [String.t()]) :: :ok
  def lay_out(%Batch{uuid: uuid} = batch, emails) do
    :ok = insert_items(uuid, emails)
    sync_total(uuid, UtilsDate.utc_now())
    lay_out(batch)
  end

  # In chunks, on conflict nothing: the case-insensitive unique index folds the
  # addresses that differ only in case (or in what the database thinks is case).
  defp insert_items(uuid, emails) do
    emails
    |> Enum.chunk_every(@item_chunk)
    |> Enum.each(fn chunk ->
      rows = Enum.map(chunk, &%{batch_uuid: uuid, email: &1})

      repo().insert_all(BatchItem, rows,
        on_conflict: :nothing,
        conflict_target: [:batch_uuid, :email]
      )
    end)
  end

  # The first run has no jobs yet, so there is nothing to look up.
  defp without_queued(items, _uuid, true), do: items

  defp without_queued(items, uuid, false) do
    queued = queued_keys(uuid)

    Enum.reject(items, fn {item_uuid, email} ->
      MapSet.member?(queued, item_uuid) or MapSet.member?(queued, email)
    end)
  end

  # Returns the number of items, which is what `total` is made to be.
  defp sync_total(uuid, now) do
    count = repo().aggregate(from(i in BatchItem, where: i.batch_uuid == ^uuid), :count)

    from(b in Batch,
      where: b.uuid == ^uuid and b.state in ["queued", "running"] and b.total != ^count
    )
    |> repo().update_all(set: [total: count, updated_at: now])

    count
  end

  # `Oban.insert_all/1` does not check `unique` (only `Oban.insert/1` does), so a
  # repeated run skips the items that still have a job by looking them up: by the
  # item uuid of a job of this version, by the address of one from an earlier version.
  # Oban may live in another schema than the repo's default one.
  defp queued_keys(uuid) do
    worker = inspect(VerifyEmailWorker)
    states = :incomplete |> Oban.Job.unique_states() |> Enum.map(&Atom.to_string/1)

    from(j in Oban.Job,
      where:
        j.worker == ^worker and j.state in ^states and
          fragment("?->>'batch_uuid' = ?", j.args, ^uuid),
      select: fragment("COALESCE(?->>'item_uuid', ?->>'email')", j.args, j.args)
    )
    |> repo().all(prefix: Oban.config().prefix)
    |> MapSet.new()
  end

  ## --- Counting (VerifyEmailWorker) ---

  @doc "The item `item_uuid` of the batch, if it is a member."
  @spec get_item_by_uuid(String.t(), term()) :: BatchItem.t() | nil
  def get_item_by_uuid(batch_uuid, item_uuid) do
    with {:ok, item_uuid} <- Ecto.UUID.cast(item_uuid),
         {:ok, batch_uuid} <- Ecto.UUID.cast(batch_uuid) do
      repo().one(
        from(i in BatchItem, where: i.uuid == ^item_uuid and i.batch_uuid == ^batch_uuid)
      )
    else
      :error -> nil
    end
  end

  @doc "The item for `email` in the batch, if it is a member."
  @spec get_item(String.t(), String.t()) :: BatchItem.t() | nil
  def get_item(batch_uuid, email) do
    repo().one(from(i in BatchItem, where: i.batch_uuid == ^batch_uuid and i.email == ^email))
  end

  @doc "Notes when a waiting item will be tried again."
  @spec schedule_retry(String.t(), String.t(), pos_integer()) :: :ok
  def schedule_retry(batch_uuid, email, seconds) do
    now = UtilsDate.utc_now()

    from(i in BatchItem,
      where: i.batch_uuid == ^batch_uuid and i.email == ^email and i.state == "pending"
    )
    |> repo().update_all(set: [next_attempt_at: DateTime.add(now, seconds), updated_at: now])

    :ok
  end

  @doc """
  Finishes the item and counts its `status` into the batch - together or not at
  all. Counting happens at most once per item, whatever the job does.

  `{:error, :already_done}` when the item was finished by an earlier run,
  `{:error, :batch_closed}` when the batch is done or cancelled.
  """
  @spec record_result(String.t(), String.t(), String.t()) ::
          {:ok, Batch.t()} | {:error, :already_done | :batch_closed}
  def record_result(batch_uuid, email, status) do
    now = UtilsDate.utc_now()

    outcome =
      repo().transaction(fn ->
        with {1, _} <- finish_item(batch_uuid, email, now),
             {1, [batch]} <- bump(batch_uuid, status, now) do
          batch
        else
          {0, _} -> repo().rollback(:rejected)
        end
      end)

    case outcome do
      {:ok, batch} ->
        # Read again: other workers have probably committed since this one did.
        broadcast(batch.uuid)
        {:ok, batch}

      {:error, :rejected} ->
        {:error, rejection(batch_uuid, email)}
    end
  end

  @doc """
  Parks the item for `email` until the SMTP queue settles it: `"pending"` becomes
  `"awaiting_smtp"` and the batch's `awaiting_smtp` goes up, together or not at all.
  Same answers as `record_result/3`: `{:error, :already_done}` when the item is not
  pending any more, `{:error, :batch_closed}` for a finished or cancelled batch.

  The verdict may land before this runs (a fast runner); then it finds nothing to
  finish. So the stored verdict is read again afterwards and, when it is already
  final, the item is finished here.
  """
  @spec await_smtp(String.t(), String.t()) ::
          {:ok, :awaiting | :settled} | {:error, :already_done | :batch_closed}
  def await_smtp(batch_uuid, email) do
    now = UtilsDate.utc_now()

    outcome =
      repo().transaction(fn ->
        with {1, _} <- park_item(batch_uuid, email, now),
             {1, _} <- bump_awaiting(batch_uuid, now) do
          :ok
        else
          {0, _} -> repo().rollback(:rejected)
        end
      end)

    case outcome do
      {:ok, :ok} ->
        settled? = settle_if_final(batch_uuid, email)
        broadcast(batch_uuid)
        {:ok, if(settled?, do: :settled, else: :awaiting)}

      {:error, :rejected} ->
        {:error, rejection(batch_uuid, email)}
    end
  end

  defp park_item(batch_uuid, email, now) do
    from(i in BatchItem,
      where: i.batch_uuid == ^batch_uuid and i.email == ^email and i.state == "pending"
    )
    |> repo().update_all(set: [state: "awaiting_smtp", next_attempt_at: nil, updated_at: now])
  end

  defp bump_awaiting(batch_uuid, now) do
    from(b in Batch, where: b.uuid == ^batch_uuid and b.state in ["queued", "running"])
    |> repo().update_all(inc: [awaiting_smtp: 1], set: [updated_at: now])
  end

  # A report that is settling the address right now may have looked for parked items
  # before this one was parked: wait for it to commit, then read the verdict.
  defp settle_if_final(batch_uuid, email) do
    :ok = SmtpQueue.wait_settled(email)

    case Verification.statuses_for([email]) do
      %{^email => %{status: status, reason: reason}} when reason != "smtp_pending" ->
        settle_item(batch_uuid, email, status)

      _ ->
        false
    end
  end

  @doc false
  # Finishes the items of `email` that wait for SMTP, in every batch, with `status`.
  # For the SMTP queue, inside its transaction: it does not broadcast (the caller does,
  # after the commit, with the batches returned) and it never rolls back, which would
  # take the caller's transaction with it.
  @spec settle_awaiting(String.t(), String.t()) :: [String.t()]
  def settle_awaiting(email, status) do
    from(i in BatchItem,
      where: i.email == ^email and i.state == "awaiting_smtp",
      order_by: i.batch_uuid,
      select: i.batch_uuid
    )
    |> repo().all()
    |> Enum.filter(&settle_item(&1, email, status))
  end

  @doc false
  # Locks, in uuid order, the open batches that wait for any of `emails`. For the SMTP
  # queue, at the start of a transaction that settles several addresses: two such
  # transactions then take the batch row locks in the same order, whatever order
  # their addresses come in, and cannot wait for each other.
  @spec lock_awaiting([String.t()]) :: :ok
  def lock_awaiting([]), do: :ok

  def lock_awaiting(emails) when is_list(emails) do
    waiting =
      from(i in BatchItem,
        where: i.email in ^emails and i.state == "awaiting_smtp",
        select: i.batch_uuid
      )

    from(b in Batch,
      where: b.uuid in subquery(waiting) and b.state in ["queued", "running"],
      order_by: b.uuid,
      lock: "FOR UPDATE",
      select: b.uuid
    )
    |> repo().all()

    :ok
  end

  # The batch row is locked first: a batch that is still open cannot close under us,
  # so the item and the counters move together without a rollback.
  defp settle_item(batch_uuid, email, status) do
    now = UtilsDate.utc_now()

    open =
      from(b in Batch,
        where:
          b.uuid == ^batch_uuid and b.state in ["queued", "running"] and b.processed < b.total,
        lock: "FOR UPDATE",
        select: b.uuid
      )
      |> repo().one()

    with true <- not is_nil(open),
         {1, _} <- finish_item(batch_uuid, email, now, "awaiting_smtp"),
         {1, _} <- bump(batch_uuid, status, now, 1) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Counts an item whose job has failed for good as `"temp"` - no verdict was reached,
  and the batch must not wait for it forever - and stores the same `"temp"`
  verdict for the address (`Verification.record_gave_up/1`), so that
  `Verification.summary/1` and the batch's own counts agree. Never raises: when
  even this fails (the database is down) it is logged, with the local part of the
  address masked, and the batch is left as it is.
  """
  @spec give_up(String.t(), String.t()) :: :ok
  def give_up(batch_uuid, email) do
    store_verdict(batch_uuid, email)

    case record_result(batch_uuid, email, "temp") do
      {:ok, _batch} -> :ok
      {:error, _already_done_or_closed} -> :ok
    end
  rescue
    error ->
      Logger.error(
        "[Emails.Verification] could not count #{mask(email)} of batch #{batch_uuid} after its last attempt: " <>
          scrub(Exception.message(error), email)
      )

      :ok
  end

  # Counting must not depend on this write.
  defp store_verdict(batch_uuid, email) do
    Verification.record_gave_up(email)
  rescue
    error ->
      Logger.error(
        "[Emails.Verification] could not store the verdict of #{mask(email)} of batch #{batch_uuid}: " <>
          scrub(Exception.message(error), email)
      )
  end

  # The message of a database error may quote the address (a query, a constraint
  # detail): it gets the same masking as the address itself.
  defp scrub(message, email) when is_binary(email) and email != "",
    do: String.replace(message, email, mask(email))

  defp scrub(message, _email), do: message

  # `john.smith@example.com` -> `j***@example.com`: enough to tell a log line from
  # another, not enough to leak the address.
  defp mask(email) when is_binary(email) do
    case String.split(email, "@") do
      [local, domain] when local != "" -> String.first(local) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp mask(_email), do: "***"

  @address ~r/[^\s<>()"',;=]+@[^\s<>()"',;=]+/

  @doc false
  # Masks every address in a free-text message (an exception message may quote
  # the rows of a failed insert), the way `give_up/2` masks its own address.
  @spec mask_addresses(String.t()) :: String.t()
  def mask_addresses(message) when is_binary(message),
    do: Regex.replace(@address, message, &mask/1)

  defp finish_item(batch_uuid, email, now, from_state \\ "pending") do
    from(i in BatchItem,
      where: i.batch_uuid == ^batch_uuid and i.email == ^email and i.state == ^from_state
    )
    |> repo().update_all(set: [state: "done", next_attempt_at: nil, updated_at: now])
  end

  # One statement: every right-hand side sees the row as it was, so `processed + 1`
  # is compared with `total` and the status counter is bumped without a read.
  defp bump(batch_uuid, status, now, awaiting \\ 0) do
    from(b in Batch,
      where: b.uuid == ^batch_uuid and b.state in ["queued", "running"] and b.processed < b.total,
      select: b,
      update: [
        set: [
          processed: fragment("? + 1", b.processed),
          counts:
            fragment(
              "jsonb_set(?, ARRAY[?]::text[], to_jsonb(COALESCE((?->>?)::integer, 0) + 1), true)",
              b.counts,
              ^status,
              b.counts,
              ^status
            ),
          state:
            fragment("CASE WHEN ? + 1 >= ? THEN 'done' ELSE ? END", b.processed, b.total, b.state),
          finished_at:
            fragment(
              "CASE WHEN ? + 1 >= ? THEN ? ELSE ? END",
              b.processed,
              b.total,
              type(^now, :utc_datetime),
              b.finished_at
            ),
          awaiting_smtp:
            fragment("GREATEST(? - ?, 0)", b.awaiting_smtp, type(^awaiting, :integer)),
          updated_at: ^now
        ]
      ]
    )
    |> repo().update_all([])
  end

  defp rejection(batch_uuid, email) do
    case get_item(batch_uuid, email) do
      %BatchItem{state: state} when state in ["done", "awaiting_smtp"] -> :already_done
      _ -> :batch_closed
    end
  end

  ## --- Reading ---

  @spec get(term()) :: Batch.t() | nil
  def get(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Batch, uuid)
      :error -> nil
    end
  end

  def get(_uuid), do: nil

  @spec list(term(), term()) :: [Batch.t()]
  def list(source_type, source_ref) do
    if Batch.storable?(source_type), do: query_list(source_type, source_ref), else: []
  end

  defp query_list(source_type, source_ref) do
    from(b in Batch,
      where: b.source_type == ^source_type,
      order_by: [desc: b.inserted_at, desc: b.uuid]
    )
    |> for_ref(ref(source_ref))
    |> repo().all()
  end

  @spec latest(term(), term()) :: Batch.t() | nil
  def latest(source_type, source_ref) do
    if Batch.storable?(source_type), do: query_latest(source_type, source_ref)
  end

  defp query_latest(source_type, source_ref) do
    from(b in Batch,
      where: b.source_type == ^source_type,
      order_by: [desc: b.inserted_at, desc: b.uuid],
      limit: 1
    )
    |> for_ref(ref(source_ref))
    |> repo().one()
  end

  defp for_ref(query, nil), do: where(query, [b], is_nil(b.source_ref))

  defp for_ref(query, ref) do
    if Batch.storable?(ref),
      do: where(query, [b], b.source_ref == ^ref),
      else: where(query, [b], false)
  end

  ## --- Cancelling ---

  @spec cancel(term()) :: {:ok, Batch.t()} | {:error, :not_found | :not_cancellable}
  def cancel(uuid) do
    case get(uuid) do
      nil -> {:error, :not_found}
      %Batch{state: "cancelled"} = batch -> {:ok, batch}
      %Batch{state: "done"} -> {:error, :not_cancellable}
      %Batch{} = batch -> close(batch)
    end
  end

  defp close(%Batch{uuid: uuid}) do
    case mark_cancelled(uuid) do
      {1, [batch]} ->
        cancel_jobs(uuid)
        SmtpQueue.cancel_for_batch(uuid)
        broadcast(batch)
        {:ok, batch}

      # The last job finished it between our read and our write.
      {0, _} ->
        cancel(uuid)
    end
  end

  defp mark_cancelled(uuid) do
    now = UtilsDate.utc_now()

    from(b in Batch, where: b.uuid == ^uuid and b.state in ["queued", "running"], select: b)
    |> repo().update_all(set: [state: "cancelled", finished_at: now, updated_at: now])
  end

  @doc """
  Cancels a batch that can no longer be laid out, from inside its own
  `BatchStartWorker`. Unlike `cancel/1` it leaves the jobs alone - cancelling the
  executing job would kill the caller; the `VerifyEmailWorker` jobs that were
  already enqueued turn themselves away on the cancelled batch.
  """
  @spec abandon(String.t()) :: :ok
  def abandon(uuid) do
    case mark_cancelled(uuid) do
      {1, [batch]} -> broadcast(batch)
      {0, _} -> :ok
    end
  end

  # Best effort: the workers check the batch state themselves, so a job that
  # cannot be cancelled here (no Oban instance, a job already executing) is
  # turned away when it runs.
  defp cancel_jobs(uuid) do
    workers = Enum.map([BatchStartWorker, VerifyEmailWorker], &inspect/1)

    Oban.cancel_all_jobs(
      from(j in Oban.Job,
        where: j.worker in ^workers and fragment("?->>'batch_uuid' = ?", j.args, ^uuid)
      )
    )

    :ok
  rescue
    error ->
      Logger.warning(
        "[Emails.Verification] could not cancel jobs of batch #{uuid}: " <>
          mask_addresses(Exception.message(error))
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Emails.Verification] could not cancel jobs of batch #{uuid}: " <>
          mask_addresses(inspect(reason))
      )

      :ok
  end

  ## --- Progress ---

  @doc "The PubSub topic of one batch's progress."
  @spec topic(String.t()) :: String.t()
  def topic(uuid), do: "email_verify:batch:" <> uuid

  @doc "Subscribes the calling process to `topic/1`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(uuid), do: PubSubManager.subscribe(topic(uuid))

  @doc "Broadcasts the batch's current progress. Best effort: it never fails the caller."
  @spec broadcast(Batch.t() | String.t()) :: :ok
  def broadcast(%Batch{} = batch) do
    PubSubManager.broadcast(topic(batch.uuid), {:email_verify_batch, snapshot(batch)})
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def broadcast(uuid) when is_binary(uuid) do
    case get(uuid) do
      %Batch{} = batch -> broadcast(batch)
      nil -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec snapshot(Batch.t()) :: snapshot()
  def snapshot(%Batch{} = batch) do
    Map.take(batch, [:uuid, :state, :processed, :total, :counts, :awaiting_smtp])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
