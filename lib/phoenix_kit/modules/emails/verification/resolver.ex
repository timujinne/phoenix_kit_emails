defmodule PhoenixKit.Modules.Emails.Verification.Resolver do
  @moduledoc """
  DNS lookups the verification pipeline needs, as a behaviour so tests (and
  hosts with a caching resolver of their own) can swap the implementation.

  An implementation answers two narrow questions and tells *definitive* answers
  from *transient* ones:

    * `:nxdomain` - the name does not exist
    * `:no_records` - the name exists but has no record of the asked type
    * `:servfail`, `:timeout` - no answer; says nothing about the name

  `resolve/2` combines them into the one question the pipeline asks: where does
  mail for this domain go.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config

  @type domain :: String.t()
  @type error :: :nxdomain | :no_records | :servfail | :timeout
  @type mx :: %{host: String.t(), pref: non_neg_integer()}
  @type resolution :: %{hosts: [mx()], implicit: boolean()}
  @type resolve_error :: :nxdomain | :no_records | :null_mx | :servfail | :timeout

  @callback lookup_mx(domain(), timeout_ms :: pos_integer()) :: {:ok, [mx()]} | {:error, error()}
  @callback lookup_addresses(domain(), timeout_ms :: pos_integer()) ::
              {:ok, [:inet.ip_address()]} | {:error, error()}

  @doc """
  Finds the mail hosts of `domain`: its MX records, or - when it has none -
  the domain itself as an implicit MX (RFC 5321 section 5.1) if it has an
  A/AAAA record.

  A transient failure of the MX query is returned as such and is not followed
  by the address fallback: an unanswered question is not an empty answer.
  An RFC 7505 "null MX" (a lone `.`) means the domain accepts no mail.

  Options: `:resolver` (module, default `Config.resolver/0`), `:timeout`
  (milliseconds, default `Config.dns_timeout_ms/0`), `:hijack_ips` (addresses
  to ignore in the fallback, or a zero-arity function returning them that is
  called only if the fallback is reached; default `[]`, see `Verification.Hijack`).
  An address answer made only of those addresses counts as no address at all.
  """
  @spec resolve(domain(), keyword()) :: {:ok, resolution()} | {:error, resolve_error()}
  def resolve(domain, opts \\ []) do
    resolver = Keyword.get_lazy(opts, :resolver, &Config.resolver/0)
    timeout = Keyword.get_lazy(opts, :timeout, &Config.dns_timeout_ms/0)

    case resolver.lookup_mx(domain, timeout) do
      {:ok, records} -> from_mx(records)
      {:error, :no_records} -> implicit_mx(resolver, domain, timeout, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_mx(records) do
    hosts =
      records
      |> Enum.map(&%{&1 | host: normalize_host(&1.host)})
      |> Enum.reject(&(&1.host == ""))
      |> Enum.sort_by(& &1.pref)

    case hosts do
      [] -> {:error, :null_mx}
      hosts -> {:ok, %{hosts: hosts, implicit: false}}
    end
  end

  defp implicit_mx(resolver, domain, timeout, opts) do
    case resolver.lookup_addresses(domain, timeout) do
      {:ok, ips} -> if genuine?(ips, opts), do: implicit(domain), else: {:error, :no_records}
      {:error, reason} -> {:error, reason}
    end
  end

  defp implicit(domain), do: {:ok, %{hosts: [%{host: domain, pref: 0}], implicit: true}}

  # At least one address that is not the one a hijacking resolver hands out.
  defp genuine?([], _opts), do: false

  defp genuine?(ips, opts) do
    hijack =
      case Keyword.get(opts, :hijack_ips, []) do
        fun when is_function(fun, 0) -> fun.()
        list -> list
      end

    Enum.any?(ips, &(&1 not in hijack))
  end

  defp normalize_host(host) do
    host |> String.downcase() |> String.trim_trailing(".")
  end
end
