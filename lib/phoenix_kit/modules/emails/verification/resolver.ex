defmodule PhoenixKit.Modules.Emails.Verification.Resolver do
  @moduledoc """
  DNS lookups the verification pipeline needs, as a behaviour so tests (and
  hosts with a caching resolver of their own) can swap the implementation.

  An implementation answers two narrow questions and tells *negative* answers
  from *transient* ones:

    * `:nxdomain` - the name does not exist
    * `:no_records` - the name exists but has no record of the asked type
    * `:servfail`, `:timeout` - no answer; says nothing about the name

  `resolve/2` combines them into the one question the pipeline asks: where does
  mail for this domain go. A negative answer is not believed on its first
  telling - see `resolve/2`. The `timeout_ms` an implementation receives is the
  deadline for the whole lookup, retries included.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config

  @type domain :: String.t()
  @type error :: :nxdomain | :no_records | :servfail | :timeout
  @type mx :: %{host: String.t(), pref: non_neg_integer()}
  @type resolution :: %{
          required(:hosts) => [mx()],
          required(:implicit) => boolean(),
          optional(:cacheable) => false
        }
  @type resolve_error :: :nxdomain | :no_records | :null_mx | :servfail | :timeout

  @callback lookup_mx(domain(), timeout_ms :: pos_integer()) :: {:ok, [mx()]} | {:error, error()}
  @callback lookup_addresses(domain(), timeout_ms :: pos_integer()) ::
              {:ok, [:inet.ip_address()]} | {:error, error()}

  @max_confirm_pause_ms 2_000

  @host_label ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @doc """
  Finds the mail hosts of `domain`: its MX records, or - when it has none -
  the domain itself as an implicit MX (RFC 5321 section 5.1) if it has an
  A/AAAA record.

  A transient failure of the MX query is returned as such and is not followed
  by the address fallback: an unanswered question is not an empty answer.
  An RFC 7505 "null MX" (a lone `.`) means the domain accepts no mail.

  A negative answer (`:nxdomain`, `:no_records`) to the MX query or to the
  address fallback is asked a second time and the second answer is the one
  returned: a resolver that lies once - a flapping forwarder, a lost reply taken
  for "no such name" - must not condemn a domain, and a domain that is
  condemned is cached for a day. The second query is made after a short pause
  (`:confirm_pause_ms`) so that the hiccup is less likely to repeat. If the second query fails transiently the
  result is that transient error. Positive answers, a null MX and transient
  errors cost one query. So a nonexistent domain costs two, a domain with an
  address only three (two MX queries, one address query).

  MX hosts that are not host names (an LDH label is 1-63 of `a-z0-9-`, not
  starting or ending with `-`; at most 253 bytes in all - so no NUL, control
  characters, spaces or non-ASCII) are dropped. If nothing else is left the
  answer is as good as none: `{:error, :servfail}`.

  Options: `:resolver` (module, default `Config.resolver/0`), `:timeout`
  (milliseconds, default `Config.dns_timeout_ms/0`), `:confirm_pause_ms`
  (milliseconds, default `Config.confirm_pause_ms/0`, at most 2000), `:hijack_ips` (addresses
  to ignore in the fallback, or a zero-arity function returning them that is
  called only if the fallback is reached; default `[]`, see `Verification.Hijack`).
  An address answer made only of those addresses counts as no address at all.
  The function may return `:error` ("could not find out"): the fallback then
  proceeds as if there were no hijack addresses, but the resolution carries
  `cacheable: false` and the caller must not remember it.
  """
  @spec resolve(domain(), keyword()) :: {:ok, resolution()} | {:error, resolve_error()}
  def resolve(domain, opts \\ []) do
    resolver = Keyword.get_lazy(opts, :resolver, &Config.resolver/0)
    timeout = Keyword.get_lazy(opts, :timeout, &Config.dns_timeout_ms/0)

    pause = confirm_pause(opts)

    case confirmed(fn -> resolver.lookup_mx(domain, timeout) end, pause) do
      {:ok, records} -> from_mx(records)
      {:error, :no_records} -> implicit_mx(resolver, domain, timeout, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # The second answer replaces the first, whatever it is.
  defp confirmed(lookup, pause) do
    case lookup.() do
      {:error, negative} when negative in [:nxdomain, :no_records] ->
        if pause > 0, do: Process.sleep(pause)
        lookup.()

      answer ->
        answer
    end
  end

  defp confirm_pause(opts) do
    case Keyword.get_lazy(opts, :confirm_pause_ms, &Config.confirm_pause_ms/0) do
      ms when is_integer(ms) and ms > 0 -> min(ms, @max_confirm_pause_ms)
      _ -> 0
    end
  end

  defp from_mx(records) do
    named =
      records
      |> Enum.map(&%{&1 | host: normalize_host(&1.host)})
      |> Enum.reject(&(&1.host == ""))

    case {named, Enum.filter(named, &host_name?(&1.host))} do
      {[], _} -> {:error, :null_mx}
      {_, []} -> {:error, :servfail}
      {_, hosts} -> {:ok, %{hosts: Enum.sort_by(hosts, & &1.pref), implicit: false}}
    end
  end

  defp host_name?(host) do
    byte_size(host) <= 253 and
      host
      |> String.split(".")
      |> Enum.all?(&(byte_size(&1) <= 63 and Regex.match?(@host_label, &1)))
  end

  defp implicit_mx(resolver, domain, timeout, opts) do
    case confirmed(fn -> resolver.lookup_addresses(domain, timeout) end, confirm_pause(opts)) do
      {:ok, []} -> {:error, :no_records}
      {:ok, ips} -> implicit_mx_from(ips, domain, hijack_ips(opts))
      {:error, reason} -> {:error, reason}
    end
  end

  # At least one address that is not the one a hijacking resolver hands out.
  defp implicit_mx_from(ips, domain, {:ok, hijack}) do
    if Enum.any?(ips, &(&1 not in hijack)), do: implicit(domain), else: {:error, :no_records}
  end

  defp implicit_mx_from(ips, domain, :error) do
    with {:ok, resolution} <- implicit_mx_from(ips, domain, {:ok, []}),
         do: {:ok, Map.put(resolution, :cacheable, false)}
  end

  defp implicit(domain), do: {:ok, %{hosts: [%{host: domain, pref: 0}], implicit: true}}

  defp hijack_ips(opts) do
    case Keyword.get(opts, :hijack_ips, []) do
      fun when is_function(fun, 0) -> known(fun.())
      value -> known(value)
    end
  end

  defp known(:error), do: :error
  defp known({:ok, list}) when is_list(list), do: {:ok, list}
  defp known(list) when is_list(list), do: {:ok, list}

  defp normalize_host(host) do
    host |> String.downcase() |> String.trim_trailing(".")
  end
end
