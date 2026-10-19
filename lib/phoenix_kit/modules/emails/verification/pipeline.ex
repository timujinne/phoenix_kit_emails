defmodule PhoenixKit.Modules.Emails.Verification.Pipeline do
  @moduledoc """
  Runs the verification steps on one address and returns an unsaved `Result`.

  | # | Step | Final outcome |
  |---|------|---------------|
  | 1 | normalise | invalid `syntax` |
  | 2 | syntax | invalid `syntax` |
  | 3 | TLD list | invalid `bad_tld` |
  | 4 | disposable list | invalid `disposable` |
  | 5 | free / role flags | - |
  | 6 | DNS MX (cache, then resolver) | invalid `no_mx`; temp `dns_error` |
  | 7 | SMTP, only when enabled | whatever the client says |

  The first final outcome stops the run. An address that gets through every
  step without an SMTP verdict is `not_sure`: `smtp_disabled` when the SMTP
  step is switched off (the domain takes mail, the mailbox is unchecked) or
  `smtp_unavailable` when it is on but the configured client cannot probe.

  Every step appends `%{"step", "outcome", "ms"}` (plus step-specific keys) to
  the result's `log`. This module only reads: it persists nothing but the MX
  answer, which goes into `DomainCache`.

  Options: `:resolver` and `:smtp` override the configured implementations.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Dictionaries
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Syntax
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @steps [:normalize, :syntax, :tld, :disposable, :flags, :mx, :smtp]

  @spec run(term(), keyword()) :: Result.t()
  def run(input, opts \\ []) do
    state = %{input: input, opts: opts, result: %Result{}, log: [], parts: nil, hosts: []}

    state =
      Enum.reduce_while(@steps, state, fn step, state ->
        {outcome, state} = timed(step, state)
        {if(outcome == :halt, do: :halt, else: :cont), state}
      end)

    finish(state)
  end

  ## --- Steps. Each returns `{:cont | :halt | :skip, state, log_extra}`. ---

  defp step(:normalize, state) do
    case Normalizer.normalize(state.input) do
      {:ok, parts} ->
        {:cont, %{state | parts: parts, result: %{state.result | email: parts.email}}, %{}}

      {:error, error} ->
        {:halt, invalid(state, "syntax", "syntax"), %{"detail" => Atom.to_string(error)}}
    end
  end

  defp step(:syntax, %{parts: %{local: local, domain: domain}} = state) do
    case Syntax.check(local, domain) do
      :ok ->
        {:cont, %{state | result: %{state.result | domain: domain}}, %{}}

      {:error, detail} ->
        {:halt, invalid(state, "syntax", "syntax"), %{"detail" => Atom.to_string(detail)}}
    end
  end

  defp step(:tld, %{parts: %{domain: domain}} = state) do
    tld = domain |> String.split(".") |> List.last()

    if Dictionaries.valid_tld?(tld) do
      {:cont, state, %{"tld" => tld}}
    else
      {:halt, invalid(state, "bad_tld", "dict"), %{"tld" => tld}}
    end
  end

  defp step(:disposable, %{parts: %{domain: domain}} = state) do
    if Dictionaries.disposable?(domain) do
      state = invalid(state, "disposable", "dict")
      {:halt, put_in(state.result.disposable, true), %{}}
    else
      {:cont, state, %{}}
    end
  end

  defp step(:flags, %{parts: %{local: local, domain: domain}} = state) do
    free = Dictionaries.free?(domain)
    role = Dictionaries.role?(local)

    {:cont, %{state | result: %{state.result | free: free, role: role}},
     %{"free" => free, "role" => role}}
  end

  defp step(:mx, %{parts: %{domain: domain}} = state) do
    {resolution, source} = resolve_mx(domain, state.opts)

    case resolution do
      {:ok, %{hosts: [%{host: host} | _] = hosts, implicit: implicit}} ->
        state = %{state | hosts: Enum.map(hosts, & &1.host)}

        {:cont, %{state | result: %{state.result | mx: host}},
         %{"hosts" => length(hosts), "implicit" => implicit, "source" => source}}

      {:error, reason} when reason in [:servfail, :timeout] ->
        {:halt, finalise(state, "temp", "dns_error", "mx"),
         %{"error" => Atom.to_string(reason), "source" => source}}

      {:error, reason} ->
        {:halt, invalid(state, "no_mx", "mx"),
         %{"error" => Atom.to_string(reason), "source" => source}}
    end
  end

  defp step(:smtp, state) do
    if Config.smtp_enabled?() do
      client = Keyword.get_lazy(state.opts, :smtp, &Config.smtp_client/0)
      {:cont, smtp_verdict(client.verify(state.result.email, state.hosts, []), state), %{}}
    else
      {:skip, finalise(state, "not_sure", "smtp_disabled", "mx"), %{}}
    end
  end

  defp smtp_verdict({:ok, %{status: status, reason: reason} = outcome}, state) do
    state = finalise(state, Atom.to_string(status), reason, "smtp")
    %{state | result: %{state.result | catch_all: Map.get(outcome, :catch_all)}}
  end

  defp smtp_verdict({:error, :unavailable}, state),
    do: finalise(state, "not_sure", "smtp_unavailable", "mx")

  defp smtp_verdict({:error, _other}, state),
    do: finalise(state, "not_sure", "smtp_error", "mx")

  ## --- Helpers ---

  defp resolve_mx(domain, opts) do
    now = UtilsDate.utc_now()

    case DomainCache.fetch_mx(domain, now) do
      {:hit, resolution} ->
        {resolution, "cache"}

      :miss ->
        resolution = Resolver.resolve(domain, Keyword.take(opts, [:resolver]))
        :ok = DomainCache.store_mx(domain, resolution, now)
        {resolution, "dns"}
    end
  end

  defp invalid(state, reason, level), do: finalise(state, "invalid", reason, level)

  defp finalise(state, status, reason, level) do
    %{state | result: %{state.result | status: status, reason: reason, level: level}}
  end

  # Runs one step, timing it and appending its log line.
  defp timed(step, state) do
    started = System.monotonic_time(:microsecond)
    {outcome, state, extra} = step(step, state)
    elapsed_ms = Float.round((System.monotonic_time(:microsecond) - started) / 1000, 2)

    line =
      Map.merge(extra, %{
        "step" => Atom.to_string(step),
        "outcome" => outcome_label(outcome),
        "ms" => elapsed_ms
      })

    {outcome, %{state | log: [line | state.log]}}
  end

  defp outcome_label(:cont), do: "ok"
  defp outcome_label(:halt), do: "fail"
  defp outcome_label(:skip), do: "skipped"

  defp finish(%{result: result, log: log, input: input}) do
    %{
      result
      | email: Normalizer.storage_key(input),
        log: Enum.reverse(log),
        checked_at: UtilsDate.utc_now(),
        source: "direct"
    }
  end
end
