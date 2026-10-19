defmodule PhoenixKit.Modules.Emails.Verification.Hijack do
  @moduledoc """
  Guards the implicit-MX fallback against DNS hijacking.

  Some resolvers (captive portals, ISPs with "helpful" error pages) answer
  NXDOMAIN with the address of their own landing page. A nonexistent domain
  would then have an A record, and through the implicit-MX rule of RFC 5321 it
  would look like a mail server.

  `ips/1` resolves a name that cannot exist - a fresh random label under `.com` -
  and returns `{:ok, addresses}` for whatever came back; `Resolver.resolve/2`
  subtracts them from the address answers it would otherwise accept. The probe is
  made lazily, only when a domain has no MX and the fallback is reached, and its
  answer is kept in `:persistent_term` for an hour per resolver implementation.
  An honest resolver costs one extra query an hour.

  A probe that could not be answered (timeout, SERVFAIL) returns `:error` and is
  not remembered, so the next domain asks again. It is **not** "no hijack":
  `Resolver.resolve/2` still lets the domain through on its address, but marks
  the resolution `cacheable: false`, and the pipeline then does not write the
  domain's MX answer to `DomainCache` - an implicit MX accepted on an unproven
  probe must not be remembered for a day.

  ## Concurrency

  The cache is one map under one `:persistent_term` key, read and rewritten
  without a lock. Two processes whose probes finish together can each write the
  map as they read it, and one entry is lost; the next call just probes again.
  The race costs one extra query, never a wrong answer, and `:persistent_term`
  updates are rare here (one per resolver implementation per hour), so it is left
  alone on purpose.
  """

  alias PhoenixKit.Modules.Emails.Verification.Config

  @key {__MODULE__, :cache}
  @ttl_seconds 3_600

  @doc """
  The addresses the probe domain resolves to - `{:ok, []}` for an honest resolver -
  or `:error` when the probe went unanswered.

  Options: `:resolver` (default `Config.resolver/0`), `:timeout`
  (default `Config.dns_timeout_ms/0`), `:probe` (the name to resolve, default
  `probe_domain/0`; for tests).
  """
  @spec ips(keyword()) :: {:ok, [:inet.ip_address()]} | :error
  def ips(opts \\ []) do
    resolver = Keyword.get_lazy(opts, :resolver, &Config.resolver/0)

    case Map.get(cache(), resolver) do
      {ips, expires_at} -> if now() < expires_at, do: {:ok, ips}, else: probe(resolver, opts)
      nil -> probe(resolver, opts)
    end
  end

  @doc "A name that does not exist: `<random>.com`, new on every call."
  @spec probe_domain() :: String.t()
  def probe_domain do
    "pk-" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false) <> ".com"
  end

  @doc "Forgets what the probes found."
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp probe(resolver, opts) do
    domain = Keyword.get_lazy(opts, :probe, &probe_domain/0)
    timeout = Keyword.get_lazy(opts, :timeout, &Config.dns_timeout_ms/0)

    case resolver.lookup_addresses(domain, timeout) do
      {:ok, ips} -> remember(resolver, ips)
      {:error, reason} when reason in [:nxdomain, :no_records] -> remember(resolver, [])
      {:error, _transient} -> :error
    end
  end

  defp remember(resolver, ips) do
    entry = {ips, now() + @ttl_seconds}
    :persistent_term.put(@key, Map.put(cache(), resolver, entry))
    {:ok, ips}
  end

  defp cache, do: :persistent_term.get(@key, %{})

  defp now, do: System.monotonic_time(:second)
end
