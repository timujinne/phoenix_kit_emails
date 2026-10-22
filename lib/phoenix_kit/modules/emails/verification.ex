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
  from an SMTP probe, which is off by default (`email_verify_smtp_mode`) and runs
  elsewhere: the server only queues the address (`Verification.SmtpQueue`) and a
  runner on the user's machine opens the connection - or, in the mode `local`, the
  server's own built-in runner (`Verification.LocalRunner`).

  ## Batches

  `start_batch/4` verifies a whole list in the background: it stores the batch with
  one item per address and returns, and a `BatchStartWorker` enqueues one
  `VerifyEmailWorker` per item to do the checking. The jobs carry uuids, never
  addresses. Progress is broadcast on `batch_topic/1`; see
  `Verification.Batches`. The workers run on the Oban queue
  `:email_verification`, which this module declares through `oban_queues/0` (limit
  5 = checks running at once, per node). A host whose Oban config predates that
  has to add it by hand, or the jobs sit in `available` forever:

      config :my_app, Oban, queues: [email_verification: 5, ...]

  `queue_configured?/0` tells whether it is there, so a UI can warn.

  See `Verification.Config` for the settings.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification.Batch
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.LocalRunner
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.QueueSweepWorker
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueue

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

  @type status_info :: %{status: String.t(), reason: String.t() | nil, level: String.t() | nil}

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
  look at `email_verify_smtp_mode` - the SMTP step is a separate, riskier
  switch - nor at `email_enabled`, which gates sending. `false` if settings
  cannot be read.
  """
  @spec enabled?() :: boolean()
  defdelegate enabled?, to: Config

  @doc """
  Verifies one address synchronously and stores the verdict.

  A stored verdict younger than `email_verify_ttl_result_days` is returned as is
  (`source: "cache"`) - except a `"temp"` one, which is always re-run; a
  `"disposable"` verdict is final whatever status the setting gives it. The MX
  answer is cached per domain either way.

  Options: `:force` (re-run even if a stored verdict is fresh), `:resolver`
  (overrides the configured implementation), `smtp: :enqueue` (when the SMTP mode
  is not `"off"`, an address that passes the MX step is stored as `not_sure` /
  `smtp_pending` and put in the SMTP queue; the verdict arrives later, from the
  queue - this function never waits for SMTP, and without the option it does not
  queue anything).

  This function does not consult `enabled?/0`: with `email_verify_enabled`
  switched off it still runs and writes. Gating the feature is the caller's job
  (hide the UI, don't enqueue the batch).
  """
  @spec verify(term(), keyword()) :: {:ok, Result.t()} | {:error, Ecto.Changeset.t()}
  def verify(email, opts \\ []) do
    case stored_fresh(email, opts) do
      %Result{} = result -> {:ok, result}
      nil -> email |> Pipeline.run(opts) |> persist() |> enqueue_pending()
    end
  end

  # A pending verdict is stored first, so a runner never settles an address that has
  # no row yet; the queue deduplicates by address.
  defp enqueue_pending({:ok, %Result{reason: "smtp_pending"} = result} = stored) do
    case SmtpQueue.enqueue(result) do
      {:ok, :queued} ->
        LocalRunner.wake()
        QueueSweepWorker.schedule()
        stored

      {:ok, _already_queued} ->
        stored

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_pending(other), do: other

  @doc """
  The stored verdicts for `emails`, keyed by the address as given.
  Addresses never verified, blank, or not storable (see
  `Normalizer.storage_key/1`) are absent.

  A verdict with the reason `"disposable"` carries the status of the current
  `email_verify_disposable_status` setting, not the one it was stored with: the
  setting is a policy, and changing it must not leave old verdicts behind.
  """
  @spec results_for([term()]) :: %{String.t() => Result.t()}
  def results_for(emails) do
    keyed = keyed(emails)
    disposable = Config.disposable_status()

    by_key =
      keyed
      |> keys()
      |> fetch_rows()
      |> Map.new(&{String.downcase(&1.email), current(%{&1 | source: "cache"}, disposable)})

    for {email, key} <- keyed, result = by_key[String.downcase(key)], into: %{} do
      {email, result}
    end
  end

  @doc """
  What `results_for/1` knows about each address, without the step log: a map
  `%{status:, reason:, level:}` (strings, as in `Verification.Result`) per address
  as given. For filtering and counting a large audience, where loading every
  verdict's `log` jsonb would be a waste.

  Absent addresses and the `"disposable"` re-mapping are as in `results_for/1`.
  """
  @spec statuses_for([term()]) :: %{term() => status_info()}
  def statuses_for(emails) do
    keyed = emails |> Enum.uniq() |> keyed()
    disposable = Config.disposable_status()

    by_key =
      keyed
      |> keys()
      |> fetch_statuses()
      |> Map.new(fn {email, info} -> {String.downcase(email), current(info, disposable)} end)

    for {email, key} <- keyed, info = by_key[String.downcase(key)], into: %{} do
      {email, info}
    end
  end

  @doc """
  Counts `emails` by stored status. `unchecked` are the ones with no verdict.
  An address listed twice counts twice.

  Built on `statuses_for/1`: it reads no step logs, and each address is
  normalised once.
  """
  @spec summary([term()]) :: summary()
  def summary(emails) do
    statuses = statuses_for(emails)

    counts =
      emails
      |> Enum.map(fn email ->
        case statuses do
          %{^email => %{status: status}} -> String.to_existing_atom(status)
          _ -> :unchecked
        end
      end)
      |> Enum.frequencies()

    for status <- [:valid, :invalid, :temp, :not_sure, :unchecked], into: %{} do
      {status, Map.get(counts, status, 0)}
    end
  end

  @doc """
  Starts verifying `emails` in the background and returns the stored batch.

  The addresses are normalised and deduplicated (blank or unstorable entries are
  dropped) and the batch is stored as `"queued"` with that `total`, together with its
  items; a `BatchStartWorker` does the rest. The items are inserted before this
  returns, so the call blocks for as long as that takes (a few seconds for the
  maximum of 100,000 addresses): a LiveView should not call it from its own process
  for a large list. `source_type` is one of
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

  @doc "The batches of one source, newest first; `[]` for a source type that is not text."
  @spec list_batches(term(), term()) :: [Batch.t()]
  defdelegate list_batches(source_type, source_ref), to: Batches, as: :list

  @doc "The newest batch of one source, or `nil` (also for a source type that is not text)."
  @spec latest_batch(term(), term()) :: Batch.t() | nil
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

  ## --- The SMTP stage ---

  @doc """
  The SMTP mode in effect: `"off"` (default), `"runner"` or `"local"`. `"runner"`
  reads `"off"` on a core without the machine API. See `Verification.Config`.
  """
  @spec smtp_mode() :: String.t()
  defdelegate smtp_mode, to: Config

  @doc """
  What the settings UI shows about the SMTP runner: whether it is online, its
  port-25 finding, a pause, the `MAIL FROM` in force, whose key it works with and
  whether that key still works, the queue length. See `Verification.Runners.status/1`.
  """
  @spec runner_status() :: map()
  def runner_status, do: Runners.status()

  @doc """
  Subscribes the calling process to runner changes: messages
  `{:email_verify_runner, %{event:, runner_uuid:}}` on the topic
  `"email_verify:runner"` (a heartbeat at most every 5 seconds, a pause or its end
  at once). Re-read `runner_status/0` on each.
  """
  @spec subscribe_runner() :: :ok | {:error, term()}
  defdelegate subscribe_runner, to: Runners, as: :subscribe

  @doc "Lifts the autopause of the runner (and forgets its failure streak). `{:ok, n}` runners were affected."
  @spec clear_runner_pause() :: {:ok, non_neg_integer()}
  defdelegate clear_runner_pause, to: Runners, as: :clear_pause

  @doc false
  # The API tools of the runner (`Emails.api_tools/0`): none on a core without the
  # machine API.
  if Code.ensure_loaded?(PhoenixKit.API.Tool) do
    alias PhoenixKit.Modules.Emails.Verification.RunnerApi

    @spec runner_tools() :: [struct()]
    def runner_tools do
      if Config.machine_api_available?(), do: RunnerApi.tools(), else: []
    end
  end

  ## --- Internals ---

  defp keyed(emails) do
    for email <- emails, key = Normalizer.storage_key(email), do: {email, key}
  end

  defp keys(keyed), do: keyed |> Enum.map(fn {_email, key} -> key end) |> Enum.uniq()

  # The disposable status is a policy, applied when a verdict is read.
  defp current(%{reason: "disposable"} = verdict, disposable), do: %{verdict | status: disposable}
  defp current(verdict, _disposable), do: verdict

  defp stored_fresh(email, opts) do
    with false <- Keyword.get(opts, :force, false),
         key when is_binary(key) <- Normalizer.storage_key(email),
         [row] <- fetch_rows([key]),
         true <- final?(row) and fresh?(row) do
      current(%{row | source: "cache"}, Config.disposable_status())
    else
      _ -> nil
    end
  end

  # A "temp" verdict is "try again later" - except a disposable domain's, which
  # is temp by policy and will not change.
  #
  # With SMTP on, a verdict that only says "the domain takes mail" is not final
  # (`smtp_disabled`, the interim `smtp_pending` unless it is still in the queue),
  # and neither is one that failed for a reason on our side or a transient one: a
  # blocked or refused connection, a timeout, a rejected sender.
  defp final?(%Result{status: "temp", reason: reason}), do: reason == "disposable"

  defp final?(%Result{status: "not_sure", reason: reason} = result)
       when reason in ~w(smtp_disabled smtp_pending smtp_unavailable smtp_connect_failed smtp_timeout smtp_reset smtp_blocked mail_from_rejected) do
    if reason == "smtp_pending",
      do: SmtpQueue.live?(result.email),
      else: not Config.smtp_enabled?()
  end

  defp final?(%Result{}), do: true

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
        select: {r.email, %{status: r.status, reason: r.reason, level: r.level}}
      )
    )
  end

  @doc false
  # The final verdict of the SMTP queue for `email`: replaces the interim
  # `smtp_pending` verdict and appends what the mail host said to its log. `verdict`
  # is `%{status:, reason:, level:, catch_all:}`, `details` may carry `:mx`, `:ms`,
  # `:code` and `:text` of the reply. Runs inside the queue's transaction.
  @spec record_smtp_result(String.t(), map(), map(), DateTime.t()) :: :ok
  def record_smtp_result(email, verdict, details, now) do
    entry = smtp_log_entry(verdict, details)

    case fetch_rows([email]) do
      [%Result{} = row] ->
        attrs = %{
          status: verdict.status,
          reason: verdict.reason,
          level: verdict.level,
          catch_all: verdict.catch_all,
          log: row.log ++ [entry],
          attempts: row.attempts + 1,
          checked_at: now
        }

        row |> Result.changeset(attrs) |> repo().update!()

      [] ->
        domain = email |> String.split("@") |> List.last()

        %Result{}
        |> Result.changeset(%{
          email: email,
          domain: domain,
          status: verdict.status,
          reason: verdict.reason,
          level: verdict.level,
          catch_all: verdict.catch_all,
          log: [entry],
          checked_at: now
        })
        |> repo().insert!()
    end

    :ok
  end

  defp smtp_log_entry(verdict, details) do
    %{"step" => "smtp_session", "outcome" => verdict.reason, "ms" => details[:ms] || 0.0}
    |> put_present("mx", details[:mx])
    |> put_present("code", details[:code])
    |> put_present("text", details[:text] && String.slice(details.text, 0, 200))
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc false
  # The verdict of an address its batch job gave up on (`Batches.give_up/2`): a
  # `"temp"` row, so that `summary/1` and `results_for/1` agree with the batch's
  # own counts. A `"temp"` verdict already stored keeps its reason (usually
  # `"dns_error"`, which says more than anything we could write here); anything
  # else, being older than the failure, is replaced.
  @spec record_gave_up(term()) :: :ok | {:error, Ecto.Changeset.t()}
  def record_gave_up(email) do
    with key when is_binary(key) <- Normalizer.storage_key(email),
         false <- match?([%Result{status: "temp"}], fetch_rows([key])),
         {:ok, _stored} <- persist(gave_up(key)) do
      :ok
    else
      {:error, _changeset} = error -> error
      _stored_or_unstorable -> :ok
    end
  end

  defp gave_up(key) do
    domain =
      case Normalizer.normalize(key) do
        {:ok, %{domain: domain}} -> domain
        {:error, _} -> nil
      end

    %Result{
      email: key,
      domain: domain,
      status: "temp",
      reason: "job_failed",
      log: [%{"step" => "batch", "outcome" => "gave_up", "ms" => 0.0}],
      checked_at: PhoenixKit.Utils.Date.utc_now()
    }
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
