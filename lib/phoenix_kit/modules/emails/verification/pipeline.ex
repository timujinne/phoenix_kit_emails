defmodule PhoenixKit.Modules.Emails.Verification.Pipeline do
  @moduledoc """
  Runs the verification steps on one address and returns an unsaved `Result`.

  | # | Step | Final outcome |
  |---|------|---------------|
  | 1 | normalise (and `+tag` strip) | invalid `syntax` |
  | 2 | syntax | invalid `syntax` |
  | 3 | marks: fake / curse / typo flags | - |
  | 4 | TLD list | invalid `bad_tld` |
  | 5 | disposable list | `email_verify_disposable_status`: temp (default) or invalid, `disposable` |
  | 6 | free / role flags | - |
  | 7 | DNS MX (cache, then resolver) | invalid `no_mx`; temp `dns_error` |
  | 8 | SMTP, only when asked to queue (`smtp: :enqueue`) and the mode is not `off` | `smtp_pending` (an interim verdict; the SMTP queue settles it) |

  The first final outcome stops the run.

  `user+tag@domain` is checked as `user@domain`: the flags, the role check and
  the SMTP client see the address without its tag, the result is stored under
  the address as given, and the `normalize` log line says what it was checked as
  (`"checked_as"`). The syntax check looks at both: the address as given, and
  what is left after the tag is cut (`user.+tag` leaves `user.`, which is not an
  address).

  The marks step comes right after the syntax check so that the flags are set
  whatever happens later (a typo domain usually ends at `no_mx`). They never
  change a status. An address that gets through every
  step without an SMTP verdict is `not_sure`: `smtp_disabled` when the SMTP
  step is not run (the domain takes mail, the mailbox is unchecked) or
  `smtp_pending` when it was asked to queue the address for SMTP: the mailbox
  is probed later, by a runner, and the verdict is replaced when its report comes.
  The pipeline itself never opens an SMTP connection.

  Every step appends `%{"step", "outcome", "ms"}` (plus step-specific keys) to
  the result's `log`. This module only reads: it persists nothing but the MX
  answer, which goes into `DomainCache`.

  Options: `:resolver` overrides the configured implementation; `smtp: :enqueue`
  makes an address that passes the MX step `smtp_pending` instead of
  `smtp_disabled` (when `Config.smtp_mode/0` is not `"off"`; the caller puts it
  in the queue); `:hijack_probe` names the domain `Hijack` resolves to detect a
  hijacking resolver (for tests).
  """

  alias PhoenixKit.Modules.Emails.Verification.Config
  alias PhoenixKit.Modules.Emails.Verification.Dictionaries
  alias PhoenixKit.Modules.Emails.Verification.DomainCache
  alias PhoenixKit.Modules.Emails.Verification.Flags
  alias PhoenixKit.Modules.Emails.Verification.Hijack
  alias PhoenixKit.Modules.Emails.Verification.Normalizer
  alias PhoenixKit.Modules.Emails.Verification.Resolver
  alias PhoenixKit.Modules.Emails.Verification.Result
  alias PhoenixKit.Modules.Emails.Verification.Syntax
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @steps [:normalize, :syntax, :marks, :tld, :disposable, :flags, :mx, :smtp]

  @spec run(term(), keyword()) :: Result.t()
  def run(input, opts \\ []) do
    state = %{
      input: input,
      opts: opts,
      result: %Result{},
      log: [],
      parts: nil,
      check_local: nil,
      key: nil
    }

    state =
      Enum.reduce_while(@steps, state, fn step, state ->
        {outcome, state} = timed(step, state)
        {if(outcome == :halt, do: :halt, else: :cont), state}
      end)

    finish(state)
  end

  ## --- Steps. Each returns `{:cont | :halt | :skip, state, log_extra}`. ---

  defp step(:normalize, state) do
    normalized = Normalizer.normalize(state.input)
    state = %{state | key: Normalizer.storage_key(state.input, normalized)}

    case normalized do
      {:ok, parts} ->
        check_local = Normalizer.strip_tag(parts.local)
        state = %{state | parts: parts, check_local: check_local}
        {:cont, %{state | result: %{state.result | email: parts.email}}, checked_as(state)}

      {:error, error} ->
        {:halt, invalid(state, "syntax", "syntax"), %{"detail" => Atom.to_string(error)}}
    end
  end

  defp step(:syntax, %{parts: %{local: local, domain: domain}} = state) do
    with :ok <- Syntax.check(local, domain),
         :ok <- Syntax.check(state.check_local, domain) do
      {:cont, %{state | result: %{state.result | domain: domain}}, %{}}
    else
      {:error, detail} ->
        {:halt, invalid(state, "syntax", "syntax"), %{"detail" => Atom.to_string(detail)}}
    end
  end

  defp step(:marks, %{parts: %{domain: domain}} = state) do
    flags = Flags.compute(state.check_local, domain)

    {:cont, %{state | result: struct!(state.result, flags)},
     Map.new(flags, fn {flag, value} -> {Atom.to_string(flag), value} end)}
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
      state = finalise(state, Config.disposable_status(), "disposable", "dict")
      {:halt, put_in(state.result.disposable, true), %{}}
    else
      {:cont, state, %{}}
    end
  end

  defp step(:flags, %{parts: %{domain: domain}} = state) do
    free = Dictionaries.free?(domain)
    role = Dictionaries.role?(state.check_local)

    {:cont, %{state | result: %{state.result | free: free, role: role}},
     %{"free" => free, "role" => role}}
  end

  defp step(:mx, %{parts: %{domain: domain}} = state) do
    {resolution, source} = resolve_mx(domain, state.opts)

    case resolution do
      {:ok, %{hosts: [%{host: host} | _] = hosts, implicit: implicit}} ->
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
    case smtp_mode(state.opts) do
      "off" -> {:skip, finalise(state, "not_sure", "smtp_disabled", "mx"), %{}}
      mode -> {:cont, finalise(state, "not_sure", "smtp_pending", "mx"), %{"mode" => mode}}
    end
  end

  # The queue is asked for explicitly: a synchronous caller does not wait for SMTP.
  defp smtp_mode(opts) do
    if Keyword.get(opts, :smtp) == :enqueue, do: Config.smtp_mode(), else: "off"
  end

  ## --- Helpers ---

  defp checked_as(%{check_local: local, parts: %{local: local}}), do: %{}

  defp checked_as(%{check_local: local, parts: %{domain: domain}}),
    do: %{"checked_as" => local <> "@" <> domain}

  @doc false
  # The MX answer for `domain`: the persistent cache, then the resolver. Also used by
  # the SMTP queue when it hands a domain to a runner, which passes `dns: false` when
  # it has no time left to ask: a cache miss is then `:no_dns`.
  @spec resolve_mx(String.t(), keyword()) ::
          {{:ok, Resolver.resolution()} | {:error, Resolver.resolve_error()}, String.t()}
          | {:no_dns, String.t()}
  def resolve_mx(domain, opts \\ []) do
    now = UtilsDate.utc_now()

    case DomainCache.fetch_mx(domain, now) do
      {:hit, resolution} ->
        {resolution, "cache"}

      :miss ->
        if Keyword.get(opts, :dns, true), do: ask_dns(domain, opts, now), else: {:no_dns, "cache"}
    end
  end

  defp ask_dns(domain, opts, now) do
    resolution = Resolver.resolve(domain, resolver_opts(opts))
    :ok = DomainCache.store_mx(domain, resolution, now)
    {resolution, "dns"}
  end

  # The anti-hijack list is a closure: the probe is made only if the MX answer
  # turns out empty and the address fallback is reached.
  defp resolver_opts(opts) do
    resolver = Keyword.get_lazy(opts, :resolver, &Config.resolver/0)
    hijack_opts = [resolver: resolver] ++ for({:hijack_probe, name} <- opts, do: {:probe, name})
    [resolver: resolver, hijack_ips: fn -> Hijack.ips(hijack_opts) end]
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

  # `key` is nil for input that cannot be stored (blank, NUL, invalid UTF-8):
  # the verdict is reported, no row is written.
  defp finish(%{result: result, log: log, key: key}) do
    %{
      result
      | email: key,
        log: Enum.reverse(log),
        checked_at: UtilsDate.utc_now(),
        source: "direct"
    }
  end
end
