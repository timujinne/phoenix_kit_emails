defmodule PhoenixKit.Modules.Emails.Verification.Batches do
  @moduledoc """
  Batches of addresses to verify: creating them, laying out their items, counting
  results into them, cancelling them. Callers use the delegating functions of
  `PhoenixKit.Modules.Emails.Verification`; the workers use the rest.

  ## Life of a batch

    1. `start/4` normalises and deduplicates the addresses, stores the batch
       (`"queued"`, with its `total`) and enqueues a `BatchStartWorker` carrying
       the addresses - both in one transaction, so there is no batch without its
       job. The caller gets the batch back at once, however long the list is.
    2. `BatchStartWorker` calls `lay_out/2`: one item per address, the batch
       becomes `"running"`, and one `VerifyEmailWorker` job per pending item.
    3. Each `VerifyEmailWorker` ends with `record_result/3`, which marks its item
       done and counts it into the batch in one transaction. The counters move in
       SQL (`processed + 1`, the status's entry in `counts`), so concurrent jobs
       never lose an update. The job that makes `processed == total` also
       makes the batch `"done"`.

  Every change is broadcast on `batch_topic/1` as
  `{:email_verify_batch, %{uuid:, state:, processed:, total:, counts:}}`.

  > #### The addresses wait in `oban_jobs` {: .warning}
  >
  > The `BatchStartWorker` job carries the whole address list in its args until
  > Oban prunes it - the price of returning from `start/4` without inserting
  > thousands of rows. Configure `Oban.Plugins.Pruner` accordingly.
  """

  import Ecto.Query
  require Logger

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.BatchItem
  alias PhoenixKit.Modules.Emails.Verification.BatchStartWorker
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.VerifyEmailWorker
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @item_chunk 1_000
  @job_chunk 500

  @type snapshot :: %{
          uuid: String.t(),
          state: String.t(),
          processed: non_neg_integer(),
          total: non_neg_integer(),
          counts: %{String.t() => non_neg_integer()}
        }

  ## --- Creating ---

  @spec start([term()], String.t(), term(), keyword()) ::
          {:ok, Batch.t()} | {:error, :no_emails | Ecto.Changeset.t() | term()}
  def start(emails, source_type, source_ref, opts) do
    case dedup(emails) do
      [] ->
        {:error, :no_emails}

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

  defp insert_with_job(changeset, keys) do
    repo().transaction(fn ->
      with {:ok, batch} <- repo().insert(changeset),
           {:ok, _job} <- enqueue_start(batch, keys) do
        batch
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp enqueue_start(batch, keys) do
    %{"batch_uuid" => batch.uuid, "emails" => keys}
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

  defp ref(nil), do: nil
  defp ref(ref), do: to_string(ref)

  ## --- Laying out (BatchStartWorker) ---

  @doc """
  Marks the batch running, inserts an item per address (the ones already there
  are left alone) and enqueues a `VerifyEmailWorker` for every item that is still
  pending. Safe to run again after a partial failure.
  """
  @spec lay_out(Batch.t(), [String.t()]) :: :ok
  def lay_out(%Batch{uuid: uuid}, emails) do
    now = UtilsDate.utc_now()

    from(b in Batch, where: b.uuid == ^uuid and b.state == "queued")
    |> repo().update_all(set: [state: "running", started_at: now, updated_at: now])

    emails
    |> Enum.chunk_every(@item_chunk)
    |> Enum.each(fn chunk ->
      rows = Enum.map(chunk, &%{batch_uuid: uuid, email: &1})

      repo().insert_all(BatchItem, rows,
        on_conflict: :nothing,
        conflict_target: [:batch_uuid, :email]
      )
    end)

    queued = queued_emails(uuid)

    from(i in BatchItem, where: i.batch_uuid == ^uuid and i.state == "pending", select: i.email)
    |> repo().all()
    |> Enum.reject(&MapSet.member?(queued, &1))
    |> Enum.chunk_every(@job_chunk)
    |> Enum.each(fn chunk ->
      chunk
      |> Enum.map(&VerifyEmailWorker.new(%{"batch_uuid" => uuid, "email" => &1}))
      |> Oban.insert_all()
    end)

    broadcast(uuid)
  end

  # `Oban.insert_all/1` does not check `unique` (only `Oban.insert/1` does), so a
  # repeated run skips the addresses that still have a job by looking them up.
  defp queued_emails(uuid) do
    worker = inspect(VerifyEmailWorker)
    states = :incomplete |> Oban.Job.unique_states() |> Enum.map(&Atom.to_string/1)

    from(j in Oban.Job,
      where:
        j.worker == ^worker and j.state in ^states and
          fragment("?->>'batch_uuid' = ?", j.args, ^uuid),
      select: fragment("?->>'email'", j.args)
    )
    |> repo().all()
    |> MapSet.new()
  end

  ## --- Counting (VerifyEmailWorker) ---

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
        broadcast(batch)
        {:ok, batch}

      {:error, :rejected} ->
        {:error, rejection(batch_uuid, email)}
    end
  end

  defp finish_item(batch_uuid, email, now) do
    from(i in BatchItem,
      where: i.batch_uuid == ^batch_uuid and i.email == ^email and i.state == "pending"
    )
    |> repo().update_all(set: [state: "done", next_attempt_at: nil, updated_at: now])
  end

  # One statement: every right-hand side sees the row as it was, so `processed + 1`
  # is compared with `total` and the status counter is bumped without a read.
  defp bump(batch_uuid, status, now) do
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
              "CASE WHEN ? + 1 >= ? THEN date_trunc('second', now()) ELSE ? END",
              b.processed,
              b.total,
              b.finished_at
            ),
          updated_at: ^now
        ]
      ]
    )
    |> repo().update_all([])
  end

  defp rejection(batch_uuid, email) do
    case get_item(batch_uuid, email) do
      %BatchItem{state: "done"} -> :already_done
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

  @spec list(String.t(), term()) :: [Batch.t()]
  def list(source_type, source_ref) do
    from(b in Batch,
      where: b.source_type == ^source_type,
      order_by: [desc: b.inserted_at, desc: b.uuid]
    )
    |> for_ref(ref(source_ref))
    |> repo().all()
  end

  @spec latest(String.t(), term()) :: Batch.t() | nil
  def latest(source_type, source_ref) do
    from(b in Batch,
      where: b.source_type == ^source_type,
      order_by: [desc: b.inserted_at, desc: b.uuid],
      limit: 1
    )
    |> for_ref(ref(source_ref))
    |> repo().one()
  end

  defp for_ref(query, nil), do: where(query, [b], is_nil(b.source_ref))
  defp for_ref(query, ref), do: where(query, [b], b.source_ref == ^ref)

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
    now = UtilsDate.utc_now()

    from(b in Batch, where: b.uuid == ^uuid and b.state in ["queued", "running"], select: b)
    |> repo().update_all(set: [state: "cancelled", finished_at: now, updated_at: now])
    |> case do
      {1, [batch]} ->
        cancel_jobs(uuid)
        broadcast(batch)
        {:ok, batch}

      # The last job finished it between our read and our write.
      {0, _} ->
        cancel(uuid)
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
        "[Emails.Verification] could not cancel jobs of batch #{uuid}: #{Exception.message(error)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "[Emails.Verification] could not cancel jobs of batch #{uuid}: #{inspect(reason)}"
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
  end

  @spec snapshot(Batch.t()) :: snapshot()
  def snapshot(%Batch{} = batch) do
    Map.take(batch, [:uuid, :state, :processed, :total, :counts])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
