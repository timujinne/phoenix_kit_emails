defmodule PhoenixKit.Modules.Emails.Verification do
  @moduledoc """
  E-mail address verification: the public API of the engine.

  An address goes through `Verification.Pipeline` (normalise, syntax, TLD,
  disposable domains, free/role flags, DNS MX, optional SMTP) and the verdict -
  a `Verification.Result` - is stored, one row per address, in
  `phoenix_kit_email_verifications`. Callers pass plain lists of addresses; the
  engine knows nothing about who owns them (CRM contacts, newsletter
  recipients, ...).

  Without SMTP an address that passes every step is `not_sure` at level `"mx"`:
  its domain accepts mail, the mailbox is unchecked. `"valid"` only ever comes
  from an SMTP probe, which is off by default (`email_verify_smtp_enabled`) and,
  in this release, has no client behind it.

  ## Batches

  `start_batch/4` verifies a whole list in the background: it returns at once
  and a `BatchStartWorker` lays the list out, then one `VerifyEmailWorker` per
  address does the checking. Progress is broadcast on `batch_topic/1`; see
  `Verification.Batches`. The workers run on the Oban queue
  `:email_verification`, which this module declares through `oban_queues/0` (limit
  5 = checks running at once, per node). A host whose Oban config predates that
  has to add it by hand, or the jobs sit in `available` forever:

      config :my_app, Oban, queues: [email_verification: 5, ...]

  `queue_configured?/0` tells whether it is there, so a UI can warn.

  See `docs/superpowers/specs/2026-10-19-email-verification.md` and
  `Verification.Config` for the settings.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Result

  @persisted [
    :email,
    :domain,
    :status,
    :reason,
    :level,
    :catch_all,
    :free,
    :role,
    :disposable,
    :fake,
    :curse,
    :typo,
    :mx,
    :log,
    :checked_at
  ]

  # A re-run overwrites every verdict field in place; the address is the key.
  @updated_on_conflict List.delete(@persisted, :email)

  @type summary :: %{
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          temp: non_neg_integer(),
          not_sure: non_neg_integer(),
          unchecked: non_neg_integer()
        }

  @doc """
  Whether verification is switched on (`email_verify_enabled`).

  Defaults to `true`: the checks that run by default (syntax, word lists, DNS)
  are passive and cost nothing to leave available. It deliberately does not
  look at `email_verify_smtp_enabled` - the SMTP step is a separate, riskier
  switch - nor at `email_enabled`, which gates sending. `false` if settings
  cannot be read.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: Config

  @doc """
  Verifies one address synchronously and stores the verdict.

  A stored verdict younger than `email_verify_ttl_result_days` is returned as is
  (`source: "cache"`) - except a `"temp"` one, which is always re-run. The MX
  answer is cached per domain either way.

  Options: `:force` (re-run even if a stored verdict is fresh), `:resolver` and
  `:smtp` (override the configured implementations).

  This function does not consult `enabled?/0`: with `email_verify_enabled`
  switched off it still runs and writes. Gating the feature is the caller's job
  (hide the UI, don't enqueue the batch).
  """
  @spec verify(term(), keyword()) :: {:ok, Result.t()} | {:error, Ecto.Changeset.t()}
  def verify(email, opts \\ []) do
    case stored_fresh(email, opts) do
      %Result{} = result -> {:ok, result}
      nil -> email |> Pipeline.run(opts) |> persist()
    end
  end

  @doc """
  The stored verdicts for `emails`, keyed by the address as given.
  Addresses never verified, blank, or not storable (see
  `Normalizer.storage_key/1`) are absent.
  """
  @spec results_for([term()]) :: %{String.t() => Result.t()}
  def results_for(emails) do
    keyed = keyed(emails)

    by_key =
      keyed
      |> keys()
      |> fetch_rows()
      |> Map.new(&{String.downcase(&1.email), %{&1 | source: "cache"}})

    for {email, key} <- keyed, result = by_key[String.downcase(key)], into: %{} do
      {email, result}
    end
  end

  @doc """
  Counts `emails` by stored status. `unchecked` are the ones with no verdict.
  An address listed twice counts twice.

  Reads only the status column, not the verdicts' step logs.
  """
  @spec summary([term()]) :: summary()
  def summary(emails) do
    statuses =
      emails
      |> keyed()
      |> keys()
      |> fetch_statuses()
      |> Map.new(fn {email, status} -> {String.downcase(email), status} end)

    counts =
      emails
      |> Enum.map(&status_of(statuses, &1))
      |> Enum.frequencies()

    for status <- [:valid, :invalid, :temp, :not_sure, :unchecked], into: %{} do
      {status, Map.get(counts, status, 0)}
    end
  end

  @doc """
  Starts verifying `emails` in the background and returns the stored batch.

  The addresses are normalised and deduplicated (blank or unstorable entries are
  dropped) and the batch is stored as `"queued"` with that `total`; a
  `BatchStartWorker` does the rest. `source_type` is one of
  `Batch.source_types/0`, `source_ref` the consumer's own handle: text, an atom, an
  integer (stored as text) or `nil`. At most `max_batch_size/0` distinct addresses.

  Options: `:title`, `:created_by_uuid`.

  `{:error, :no_emails}` when nothing storable is left, `{:error, :too_many_emails}`
  over the maximum, `{:error, changeset}` for an unknown `source_type` or a
  `source_ref`/`title` that is not storable text, and `{:error, reason}` when the
  batch could not be stored or its job not enqueued (no Oban instance, the database).
  Like `verify/2` this does not consult `enabled?/0`.
  """
  @spec start_batch([term()], String.t(), term(), keyword()) ::
          {:ok, Batch.t()}
          | {:error, :no_emails | :too_many_emails | Ecto.Changeset.t() | term()}
  def start_batch(emails, source_type, source_ref, opts \\ []) when is_list(emails) do
    Batches.start(emails, source_type, source_ref, opts)
  end

  @doc "The batch, or `nil` (also for something that is not a uuid)."
  @spec get_batch(term()) :: Batch.t() | nil
  defdelegate get_batch(uuid), to: Batches, as: :get

  @doc "The batches of one source, newest first."
  @spec list_batches(String.t(), term()) :: [Batch.t()]
  defdelegate list_batches(source_type, source_ref), to: Batches, as: :list

  @doc "The newest batch of one source, or `nil`."
  @spec latest_batch(String.t(), term()) :: Batch.t() | nil
  defdelegate latest_batch(source_type, source_ref), to: Batches, as: :latest

  @doc """
  Cancels a batch that is not finished: its state becomes `"cancelled"` and its
  waiting jobs are cancelled. Addresses already verified keep their verdicts.

  `{:error, :not_cancellable}` for a batch that is `"done"`, `{:error, :not_found}`
  for an unknown one. Cancelling a cancelled batch is a no-op.
  """
  @spec cancel_batch(term()) :: {:ok, Batch.t()} | {:error, :not_found | :not_cancellable}
  defdelegate cancel_batch(uuid), to: Batches, as: :cancel

  @doc """
  Subscribes the calling process to the batch's progress: messages
  `{:email_verify_batch, %{uuid:, state:, processed:, total:, counts:}}`, the last
  one with `state: "done"` (or `"cancelled"`).

  Workers run in parallel, so messages can arrive out of order: ignore a snapshot
  whose `processed` is lower than the one you already hold (or re-read the batch
  with `get_batch/1` on every message).
  """
  @spec subscribe_batch(String.t()) :: :ok | {:error, term()}
  defdelegate subscribe_batch(uuid), to: Batches, as: :subscribe

  @doc "The most distinct addresses one batch can hold; `start_batch/4` refuses more."
  @spec max_batch_size() :: pos_integer()
  defdelegate max_batch_size, to: Batches, as: :max_size

  @doc "The PubSub topic of a batch: `\"email_verify:batch:<uuid>\"`."
  @spec batch_topic(String.t()) :: String.t()
  defdelegate batch_topic(uuid), to: Batches, as: :topic

  @doc """
  Whether the host's Oban config declares the `:email_verification` queue.

  Without it batch jobs are stored and never run (`Oban.insert/1` accepts a job
  for a queue nobody works), so a UI offering to verify a list should warn when
  this is `false`. Reads the parent app's compile-time Oban config, like
  `Emails.Queue.runnable?/0`; a queue map or an Oban started at runtime reads as
  not configured.
  """
  @spec queue_configured?() :: boolean()
  def queue_configured? do
    PhoenixKit.Config.get_parent_app()
    |> Application.get_env(Oban, [])
    |> Keyword.get(:queues, [])
    |> then(fn
      queues when is_list(queues) -> Keyword.has_key?(queues, :email_verification)
      _ -> false
    end)
  rescue
    _ -> false
  end

  ## --- Internals ---

  defp keyed(emails) do
    for email <- emails, key = Normalizer.storage_key(email), do: {email, key}
  end

  defp keys(keyed), do: keyed |> Enum.map(fn {_email, key} -> key end) |> Enum.uniq()

  defp status_of(statuses, email) do
    with key when is_binary(key) <- Normalizer.storage_key(email),
         status when is_binary(status) <- Map.get(statuses, String.downcase(key)) do
      String.to_existing_atom(status)
    else
      _ -> :unchecked
    end
  end

  defp stored_fresh(email, opts) do
    with false <- Keyword.get(opts, :force, false),
         key when is_binary(key) <- Normalizer.storage_key(email),
         [row] <- fetch_rows([key]),
         true <- row.status != "temp" and fresh?(row) do
      %{row | source: "cache"}
    else
      _ -> nil
    end
  end

  defp fresh?(%Result{checked_at: %DateTime{} = at}) do
    DateTime.diff(PhoenixKit.Utils.Date.utc_now(), at, :second) < Config.ttl_seconds(:result)
  end

  defp fresh?(_result), do: false

  defp fetch_rows([]), do: []

  defp fetch_rows(keys) do
    repo().all(from(r in Result, where: fragment("? = ANY(?::citext[])", r.email, ^keys)))
  end

  defp fetch_statuses([]), do: []

  defp fetch_statuses(keys) do
    repo().all(
      from(r in Result,
        where: fragment("? = ANY(?::citext[])", r.email, ^keys),
        select: {r.email, r.status}
      )
    )
  end

  # A blank input has nothing to key a row on: report it, store nothing.
  defp persist(%Result{email: nil} = result), do: {:ok, result}

  defp persist(%Result{} = result) do
    changeset = Result.changeset(%Result{}, Map.take(result, @persisted))

    overwrite =
      result
      |> Map.take(@updated_on_conflict)
      |> Map.put(:updated_at, result.checked_at)
      |> Enum.to_list()

    on_conflict = from(r in Result, update: [set: ^overwrite, inc: [attempts: 1]])

    case repo().insert(changeset,
           on_conflict: on_conflict,
           conflict_target: :email,
           returning: true
         ) do
      {:ok, stored} -> {:ok, %{stored | source: "direct"}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
