defmodule PhoenixKit.Modules.Emails.Verification.SmtpQueue do
  @moduledoc """
  The queue of addresses waiting for an SMTP session, and the two calls a runner
  makes on it (spec `docs/superpowers/specs/2026-10-20-smtp-runner.md`, sections 3.2
  to 3.4). This module never opens a connection: it hands work out (`claim/3`) and
  settles what comes back (`report/3`).

  ## Life of a row

    1. `enqueue/1` - an address that passed the MX step is queued once
       (a unique index on the live states; a second batch asking for the same address
       shares the row).
    2. `claim/3` - a runner takes a *session*: up to `rcpt_per_session` queued
       addresses of one domain, with the domain's MX hosts and, when the domain's
       catch-all fact is unknown or expired, a random probe address. A domain is
       handed out only when no session of it is running anywhere, its last session
       ended `domain_interval_s` ago, it is not paused, and the rows are due
       (`not_before`). The rows are `leased` for `smtp_lease_s`.
    3. `report/3` - the runner reports the raw facts of the session; the
       `Classifier` turns them into verdicts. A final verdict is written to the
       address's result row, closes the queue row (`done`) and finishes the address
       in every batch awaiting it. A greylist, a refused connection and the like put
       the row back (`queued`, `attempts + 1`, a later `not_before`) until the
       attempts run out and the verdict that goes with that is kept.
    4. A lease that nobody reported on expires: the next claim puts the row back
       (`lease_expiries + 1`, the token kept so that a late report is still
       accepted until the row is leased again); after `smtp_max_attempts` expiries
       it is settled as `not_sure` / `smtp_unavailable`.

  `cancel_for_batch/1` drops the queued rows of a cancelled batch unless another
  live batch still needs the address.

  ## Retry timing

  A greylisted address waits `email_verify_grey_retry_minutes` and is tried at most
  `email_verify_grey_max_attempts` times in all. A failed connection waits one
  minute, then five, then the verdict is kept (three attempts). A lease that
  expired is counted up to `email_verify_smtp_max_attempts`. The three kinds have
  their own counters on the row (`grey_attempts`, `transport_attempts`,
  `lease_expiries`): one kind of trouble does not use up the allowance of another.
  `attempts` is their total.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Emails.Verification
  alias PhoenixKit.Modules.Emails.Verification.Batches
  alias PhoenixKit.Modules.Emails.Verification.Classifier
  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Dictionaries
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Pipeline
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Runner
  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Verification.SmtpQueueItem, as: Item
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @max_sessions 20
  @max_mx_hosts 5
  @transport_backoff_s [60, 300]
  @text_limit 512
  @max_entries 200
  @outcomes ~w(answered connect_failed timeout reset)
  @commands ~w(banner ehlo mail rcpt_probe)
  @local "local"

  @type session :: %{
          lease: String.t(),
          domain: String.t(),
          mx: [String.t()],
          probe: String.t() | nil,
          rcpt: [%{id: String.t(), email: String.t()}]
        }
  @type claimant :: Runner.t() | :local
  @type report_summary :: %{
          accepted: non_neg_integer(),
          ignored: non_neg_integer(),
          rejected: non_neg_integer(),
          settled: non_neg_integer()
        }

  ## --- Enqueue ---

  @doc """
  Queues the address of `result` (a `smtp_pending` verdict) for an SMTP session.
  `{:ok, :queued}`, or `{:ok, :already_queued}` when the address already waits.
  """
  @spec enqueue(Result.t()) :: {:ok, :queued | :already_queued} | {:error, :bad_address}
  def enqueue(%Result{email: email}) when is_binary(email) do
    case Normalizer.normalize(email) do
      {:ok, %{local: local, domain: domain}} ->
        row = %{
          email: email,
          checked_as: Normalizer.strip_tag(local) <> "@" <> domain,
          domain: domain
        }

        {count, _} =
          repo().insert_all(Item, [row],
            on_conflict: :nothing,
            conflict_target: {:unsafe_fragment, "(email) WHERE state IN ('queued', 'leased')"}
          )

        {:ok, if(count == 1, do: :queued, else: :already_queued)}

      {:error, _reason} ->
        {:error, :bad_address}
    end
  end

  def enqueue(_result), do: {:error, :bad_address}

  @doc "Whether `email` has a row that is still `queued` or `leased`."
  @spec live?(String.t()) :: boolean()
  def live?(email) when is_binary(email) do
    repo().exists?(from(q in Item, where: q.email == ^email and q.state in ["queued", "leased"]))
  end

  @doc "Rows by state: `%{queued:, leased:}`."
  @spec counts() :: %{queued: non_neg_integer(), leased: non_neg_integer()}
  def counts do
    counts =
      from(q in Item,
        where: q.state in ["queued", "leased"],
        group_by: q.state,
        select: {q.state, count(q.uuid)}
      )
      |> repo().all()
      |> Map.new()

    %{queued: Map.get(counts, "queued", 0), leased: Map.get(counts, "leased", 0)}
  end

  @doc """
  Cancels the queued rows of the addresses `batch_uuid` is waiting for, except those
  another live batch (queued or running) is still waiting for. A row a runner holds
  is left to finish: its result is welcome anyway.
  """
  @spec cancel_for_batch(String.t()) :: non_neg_integer()
  def cancel_for_batch(batch_uuid) do
    now = UtilsDate.utc_now()

    emails =
      from(i in Verification.BatchItem,
        where: i.batch_uuid == ^batch_uuid and i.state == "awaiting_smtp",
        select: i.email
      )

    needed_elsewhere =
      from(i in Verification.BatchItem,
        join: b in Verification.Batch,
        on: b.uuid == i.batch_uuid,
        where:
          i.batch_uuid != ^batch_uuid and i.state in ["pending", "awaiting_smtp"] and
            b.state in ["queued", "running"],
        select: i.email
      )

    {count, _} =
      from(q in Item,
        where:
          q.state == "queued" and q.email in subquery(emails) and
            q.email not in subquery(needed_elsewhere)
      )
      |> repo().update_all(
        set: [state: "cancelled", last_reason: "batch_cancelled", updated_at: now]
      )

    count
  end

  ## --- Claim ---

  @doc """
  Hands out up to `max_sessions` sessions (see the moduledoc) to `claimant`: a
  `Runner` row, or `:local` for the built-in runner.

    * `{:paused, reason}` - the runner is paused (autopause); nothing is leased
    * `{:ok, sessions}` - possibly empty. Always empty while no `MAIL FROM` is
      configured (`Config.smtp_mail_from/0`): no session may start without a sender.

  Leases that have run out are swept first, whoever asks.
  """
  @spec claim(claimant(), integer(), DateTime.t()) :: {:ok, [session()]} | {:paused, String.t()}
  def claim(claimant, max_sessions, now \\ UtilsDate.utc_now()) do
    expire_leases(now)

    cond do
      paused?(claimant, now) -> {:paused, claimant.pause_reason || "paused"}
      max_sessions < 1 or not mail_from?() -> {:ok, []}
      true -> {:ok, lease_sessions(claimant, min(max_sessions, @max_sessions), now)}
    end
  end

  defp paused?(%Runner{paused_until: %DateTime{} = until}, now),
    do: DateTime.compare(until, now) == :gt

  defp paused?(_claimant, _now), do: false

  defp mail_from?, do: match?({address, _source} when is_binary(address), Config.smtp_mail_from())

  defp lease_sessions(claimant, max_sessions, now) do
    claimant_id = claimant_id(claimant)

    max_sessions
    |> candidate_domains(now)
    |> Enum.reduce_while([], fn domain, sessions ->
      sessions =
        case lease_domain(domain, claimant_id, now) do
          {:ok, session} -> sessions ++ [session]
          :skip -> sessions
        end

      if length(sessions) >= max_sessions, do: {:halt, sessions}, else: {:cont, sessions}
    end)
  end

  defp claimant_id(%Runner{uuid: uuid}), do: uuid
  defp claimant_id(:local), do: @local

  # Domains with something due, nobody holding a session of them, past their pause
  # and their spacing; oldest waiter first. More than asked for, as some are skipped.
  defp candidate_domains(max_sessions, now) do
    cutoff = DateTime.add(now, -Config.domain_interval_s(), :second)
    leased = from(l in Item, where: l.state == "leased", select: l.domain)

    from(q in Item,
      left_join: d in DomainCache,
      on: d.domain == q.domain,
      where: q.state == "queued" and (is_nil(q.not_before) or q.not_before <= ^now),
      where: is_nil(d.paused_until) or d.paused_until <= ^now,
      where: is_nil(d.last_smtp_at) or d.last_smtp_at <= ^cutoff,
      where: q.domain not in subquery(leased),
      group_by: q.domain,
      order_by: [asc: min(q.inserted_at), asc: q.domain],
      limit: ^(max_sessions * 3),
      select: q.domain
    )
    |> repo().all()
  end

  defp lease_domain(domain, claimant_id, now) do
    case mx_hosts(domain) do
      {:ok, hosts} -> lease_rows(domain, hosts, claimant_id, now)
      {:dead, _reason} -> settle_dead_domain(domain, now)
      :transient -> :skip
    end
  end

  # From the cache, then DNS (the MX was cached when the address was queued, so DNS
  # is the exception). A definitive negative answer means the domain lost its mail
  # host since; a transient failure leaves the rows queued for the next claim.
  defp mx_hosts(domain) do
    case Pipeline.resolve_mx(domain, []) do
      {{:ok, %{hosts: [_ | _] = hosts}}, _source} ->
        {:ok, hosts |> Enum.map(& &1.host) |> Enum.take(@max_mx_hosts)}

      {{:error, reason}, _source} when reason in [:servfail, :timeout] ->
        :transient

      {{:error, reason}, _source} ->
        {:dead, reason}

      _other ->
        :transient
    end
  end

  defp lease_rows(domain, hosts, claimant_id, now) do
    outcome =
      repo().transaction(fn ->
        with true <- try_lock(domain),
             false <- domain_leased?(domain),
             domain_row = DomainCache.get(domain),
             true <- domain_ready?(domain_row, now),
             [_ | _] = rows <- due_rows(domain, now) do
          lease(rows, hosts, domain_row, claimant_id, now)
        else
          _ -> repo().rollback(:skip)
        end
      end)

    case outcome do
      {:ok, session} -> {:ok, session}
      {:error, :skip} -> :skip
    end
  end

  # One claim at a time per domain: two claims racing for the same domain would
  # both see "no live lease". The lock is held until the transaction ends.
  defp try_lock(domain) do
    %{rows: [[locked]]} =
      repo().query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
        "pke_smtp:" <> domain
      ])

    locked
  end

  defp domain_leased?(domain),
    do: repo().exists?(from(l in Item, where: l.domain == ^domain and l.state == "leased"))

  defp domain_ready?(nil, _now), do: true

  defp domain_ready?(%DomainCache{} = row, now) do
    cutoff = DateTime.add(now, -Config.domain_interval_s(), :second)

    not future?(row.paused_until, now) and
      (is_nil(row.last_smtp_at) or DateTime.compare(row.last_smtp_at, cutoff) != :gt)
  end

  defp future?(nil, _now), do: false
  defp future?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :gt

  defp due_rows(domain, now) do
    from(q in Item,
      where:
        q.domain == ^domain and q.state == "queued" and
          (is_nil(q.not_before) or q.not_before <= ^now),
      order_by: [asc: q.inserted_at, asc: q.uuid],
      limit: ^Config.rcpt_per_session(),
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> repo().all()
  end

  defp lease(rows, hosts, domain_row, claimant_id, now) do
    token = new_token()
    expires = DateTime.add(now, Config.smtp_lease_s(), :second)
    ids = Enum.map(rows, & &1.uuid)

    from(q in Item, where: q.uuid in ^ids)
    |> repo().update_all(
      set: [
        state: "leased",
        lease_token: token,
        leased_by: claimant_id,
        lease_expires_at: expires,
        updated_at: now
      ]
    )

    domain = hd(rows).domain

    %{
      lease: token,
      domain: domain,
      mx: hosts,
      probe: probe(domain, domain_row, now),
      rcpt: Enum.map(rows, &%{id: &1.uuid, email: &1.checked_as})
    }
  end

  # A random address at the domain, asked about only to see whether the host accepts
  # anything. Not for free or disposable domains, and not while the fact is fresh.
  defp probe(domain, domain_row, now) do
    cond do
      Dictionaries.free?(domain) or Dictionaries.disposable?(domain) -> nil
      known_catch_all(domain_row, now) != :unknown -> nil
      true -> "x" <> random_text(9) <> "@" <> domain
    end
  end

  defp known_catch_all(%DomainCache{catch_all: value} = row, now) when is_boolean(value) do
    if DomainCache.fresh?(row, :catch_all, now), do: value, else: :unknown
  end

  defp known_catch_all(_row, _now), do: :unknown

  defp new_token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp random_text(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, length)
  end

  # The domain has no mail host any more: nothing to ask, the address cannot receive.
  defp settle_dead_domain(domain, now) do
    verdict = %{status: "invalid", reason: "no_mx", level: "mx", catch_all: nil}

    {:ok, batches} =
      repo().transaction(fn ->
        from(q in Item,
          where: q.domain == ^domain and q.state == "queued",
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> repo().all()
        |> Enum.flat_map(fn row ->
          {:settled, batches} = settle_final(row, verdict, %{}, now)
          batches
        end)
      end)

    broadcast_batches(batches)
    :skip
  end

  ## --- Expiry ---

  @doc """
  Takes back the sessions whose lease has run out: the rows go back to `queued` with
  `attempts + 1`, or, after `smtp_max_attempts`, are settled as `not_sure` /
  `smtp_unavailable`. Returns how many rows it touched.
  """
  @spec expire_leases(DateTime.t()) :: non_neg_integer()
  def expire_leases(now \\ UtilsDate.utc_now()) do
    {:ok, {count, batches}} =
      repo().transaction(fn ->
        rows =
          from(q in Item,
            where: q.state == "leased" and q.lease_expires_at <= ^now,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> repo().all()

        batches = Enum.flat_map(rows, &expire(&1, now))
        {length(rows), batches}
      end)

    broadcast_batches(batches)
    count
  end

  defp expire(%Item{} = row, now) do
    expiries = row.lease_expiries + 1
    row = %{row | attempts: row.attempts + 1, lease_expiries: expiries}

    if expiries >= Config.smtp_max_attempts() do
      verdict = %{status: "not_sure", reason: "smtp_unavailable", level: "mx", catch_all: nil}
      {:settled, batches} = settle_final(row, verdict, %{}, now)
      batches
    else
      requeue(row, [lease_expiries: expiries], nil, "lease_expired", now, keep_lease: true)
      []
    end
  end

  ## --- Report ---

  @doc """
  Takes the facts of finished sessions from `claimant`.

  Each result is `%{"lease" =>, "outcome" =>, "mx_used" =>, "steps" =>, "rcpt" =>, "ms" =>}`
  (string keys, as decoded from JSON; texts are cut to #{@text_limit} characters). A
  result for a lease that is not this claimant's, or no longer held (settled,
  cancelled, taken back and leased again), is ignored, so a repeated report is
  harmless; a lease that has expired but not been taken back yet is still accepted.
  A result of the wrong shape is rejected.

  Options: `:phrases` - phrase lists for the `Classifier` (tests).
  """
  @spec report(claimant(), [map()], DateTime.t(), keyword()) :: {:ok, report_summary()}
  def report(claimant, results, now \\ UtilsDate.utc_now(), opts \\ []) when is_list(results) do
    summary = %{accepted: 0, ignored: 0, rejected: 0, settled: 0}

    summary =
      Enum.reduce(results, summary, fn result, acc ->
        case settle_report(claimant, result, now, opts) do
          {:accepted, settled} ->
            %{acc | accepted: acc.accepted + 1, settled: acc.settled + settled}

          :ignored ->
            %{acc | ignored: acc.ignored + 1}

          :rejected ->
            %{acc | rejected: acc.rejected + 1}
        end
      end)

    {:ok, summary}
  end

  defp settle_report(claimant, result, now, opts) do
    case parse_result(result) do
      {:ok, session} -> claimant |> apply_report(session, now, opts) |> announce()
      :error -> :rejected
    end
  end

  defp announce({:ok, {:accepted, settled, batches, events}}) do
    broadcast_batches(batches)
    Enum.each(events, &Runners.broadcast/1)
    {:accepted, settled}
  end

  defp announce({:ok, :ignored}), do: :ignored

  defp apply_report(claimant, session, now, opts) do
    repo().transaction(fn ->
      claimant_id = claimant_id(claimant)

      rows =
        from(q in Item,
          where:
            q.lease_token == ^session.lease and q.leased_by == ^claimant_id and
              q.state in ["leased", "queued"],
          order_by: [asc: q.inserted_at, asc: q.uuid],
          lock: "FOR UPDATE"
        )
        |> repo().all()

      case rows do
        [] -> :ignored
        rows -> settle_session(claimant, rows, session, now, opts)
      end
    end)
  end

  defp settle_session(claimant, [%Item{domain: domain} | _] = rows, session, now, opts) do
    classification =
      Classifier.classify(
        session,
        Enum.map(rows, & &1.uuid),
        Keyword.take(opts, [:phrases]) ++ [catch_all: cached_catch_all(domain, now)]
      )

    details = %{mx: session.mx_used, ms: session.ms}
    rcpt = Map.new(session.rcpt, &{&1.id, &1})

    {settled, batches} =
      Enum.reduce(rows, {0, []}, fn row, {count, batches} ->
        verdict = Map.fetch!(classification.verdicts, row.uuid)
        row_details = Map.merge(details, reply(rcpt[row.uuid]))

        case apply_verdict(row, verdict, row_details, now) do
          {:settled, moved} -> {count + 1, batches ++ moved}
          :requeued -> {count, batches}
        end
      end)

    _ = DomainCache.record_session(domain, classification.domain, now)

    events =
      Runners.record_session(claimant, domain, classification, session.outcome, settled, now)

    {:accepted, settled, batches, events}
  end

  defp reply(nil), do: %{}
  defp reply(%{code: code, text: text}), do: %{code: code, text: text}

  # The cached fact, as the classifier wants it: free and disposable domains are never
  # probed and count as "not catch-all".
  defp cached_catch_all(domain, now) do
    if Dictionaries.free?(domain) or Dictionaries.disposable?(domain) do
      false
    else
      case known_catch_all(DomainCache.get(domain), now) do
        :unknown -> nil
        value -> value
      end
    end
  end

  defp apply_verdict(row, %{action: :final} = verdict, details, now),
    do: settle_final(row, verdict, details, now)

  defp apply_verdict(row, %{action: :retry, kind: :grey} = verdict, _details, now) do
    grey = row.grey_attempts + 1
    row = %{row | attempts: row.attempts + 1, grey_attempts: grey}

    if grey >= Config.grey_max_attempts() do
      settle_final(row, verdict.exhausted, %{}, now)
    else
      wait = Config.grey_retry_minutes() * 60
      counters = [grey_attempts: grey]
      requeue(row, counters, DateTime.add(now, wait, :second), verdict.exhausted.reason, now)
    end
  end

  defp apply_verdict(row, %{action: :retry, kind: :transport} = verdict, _details, now) do
    transport = row.transport_attempts + 1
    row = %{row | attempts: row.attempts + 1, transport_attempts: transport}

    case Enum.at(@transport_backoff_s, transport - 1) do
      nil ->
        settle_final(row, verdict.exhausted, %{}, now)

      wait ->
        counters = [transport_attempts: transport]
        retry_at = DateTime.add(now, wait, :second)
        requeue(row, counters, retry_at, verdict.exhausted.reason, now)
    end
  end

  # Back to the queue. A report clears the lease (its token is spent: a repeat of the
  # report is ignored); an expired lease keeps it, for a late report (`keep_lease`).
  defp requeue(row, counters, not_before, reason, now, opts \\ []) do
    lease =
      if Keyword.get(opts, :keep_lease, false),
        do: [lease_expires_at: nil],
        else: [lease_token: nil, leased_by: nil, lease_expires_at: nil]

    from(q in Item, where: q.uuid == ^row.uuid)
    |> repo().update_all(
      set:
        [
          state: "queued",
          attempts: row.attempts,
          not_before: not_before,
          last_reason: reason,
          updated_at: now
        ] ++ counters ++ lease
    )

    :requeued
  end

  # Writes the verdict to the address's result, closes the row, finishes the address
  # in the batches waiting for it; returns those, to be announced once the
  # transaction has committed.
  defp settle_final(row, verdict, details, now) do
    :ok = Verification.record_smtp_result(row.email, verdict, details, now)

    from(q in Item, where: q.uuid == ^row.uuid)
    |> repo().update_all(
      set: [
        state: "done",
        attempts: row.attempts,
        grey_attempts: row.grey_attempts,
        transport_attempts: row.transport_attempts,
        lease_expiries: row.lease_expiries,
        lease_token: nil,
        leased_by: nil,
        lease_expires_at: nil,
        last_reason: verdict.reason,
        updated_at: now
      ]
    )

    {:settled, Batches.settle_awaiting(row.email, verdict.status)}
  end

  defp broadcast_batches(batches) do
    batches |> Enum.uniq() |> Enum.each(&Batches.broadcast/1)
  end

  ## --- Parsing a reported session ---

  defp parse_result(%{"lease" => lease, "outcome" => outcome} = result)
       when is_binary(lease) and outcome in @outcomes do
    with {:ok, steps} <- parse_entries(Map.get(result, "steps", []), "cmd", @commands),
         {:ok, rcpt} <- parse_entries(Map.get(result, "rcpt", []), "id", :any) do
      {:ok,
       %{
         lease: lease,
         outcome: outcome,
         mx_used: text(Map.get(result, "mx_used"), 255),
         ms: milliseconds(Map.get(result, "ms")),
         steps: Enum.map(steps, fn {key, code, text} -> %{cmd: key, code: code, text: text} end),
         rcpt: Enum.map(rcpt, fn {key, code, text} -> %{id: key, code: code, text: text} end)
       }}
    end
  end

  defp parse_result(_result), do: :error

  defp parse_entries(entries, _key, _allowed) when not is_list(entries), do: :error
  defp parse_entries(entries, _key, _allowed) when length(entries) > @max_entries, do: :error

  defp parse_entries(entries, key, allowed) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case parse_entry(entry, key, allowed) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :skip -> {:cont, {:ok, acc}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  # A step of a command this server does not know is skipped (a newer runner may log
  # more); a code that is not a three-digit number is not a reply at all.
  defp parse_entry(%{"code" => code} = entry, key, allowed)
       when is_integer(code) and code in 0..999 do
    id = Map.get(entry, key)

    cond do
      not is_binary(id) -> :error
      allowed != :any and id not in allowed -> :skip
      true -> {:ok, {id, code, text(Map.get(entry, "text"), @text_limit)}}
    end
  end

  defp parse_entry(_entry, _key, _allowed), do: :error

  defp text(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp text(_value, _limit), do: ""

  defp milliseconds(ms) when is_integer(ms) and ms >= 0, do: ms
  defp milliseconds(_ms), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
