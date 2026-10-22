defmodule PhoenixKit.Modules.Emails.Verification.Resolver.Inet do
  @moduledoc """
  `Verification.Resolver` backed by OTP's `:inet_res`.

  `:inet_res.lookup/4` flattens every failure to `[]`; `:inet_res.resolve/5` is
  used instead because the pipeline has to tell "this domain has no mail
  server" (negative) from "the resolver did not answer" (try again later).

  ## Absolute names

  Every name is queried with a trailing dot (`"gmail.com."`), so a `search`
  domain in the host's `resolv.conf` can never be appended to it - a container
  with `search something.ts.net` must not turn a lookup of `gmail.com` into one
  of `gmail.com.something.ts.net` and bring back that name's NXDOMAIN.

  ## Time

  `timeout_ms` is one deadline for a whole query, retransmissions and every name
  server included (`:inet_res.resolve/5`'s overall `Timeout`); inside it the
  query is sent twice. `lookup_mx/2` is therefore at most `timeout_ms`, and
  `lookup_addresses/2` at most twice that (A, then AAAA when A found nothing).
  `Resolver.resolve/2` asks a negative answer a second time and the pipeline's
  anti-hijack probe is one more `lookup_addresses/2`, so the worst case for one
  domain with the default 3 s is: MX 2 x 3 s, addresses 2 x 2 x 3 s, probe 2 x 3 s
  = 24 s, plus the two confirmation pauses (`Config.confirm_pause_ms/0`, 300 ms
  by default); a nonexistent domain answered promptly costs two round trips and
  one pause.
  """

  @behaviour PhoenixKit.Modules.Emails.Verification.Resolver

  @impl true
  def lookup_mx(domain, timeout_ms) do
    with {:ok, message} <- query(domain, :mx, timeout_ms) do
      case mx_records(message) do
        [] -> {:error, :no_records}
        records -> {:ok, records}
      end
    end
  end

  # AAAA is asked only when A found nothing: one address is enough for the
  # implicit-MX fallback, and every extra query is another timeout to wait for.
  @impl true
  def lookup_addresses(domain, timeout_ms) do
    case address_query(domain, :a, timeout_ms) do
      {:ok, _ips} = found ->
        found

      {:error, a_error} ->
        case address_query(domain, :aaaa, timeout_ms) do
          {:ok, _ips} = found -> found
          {:error, aaaa_error} -> {:error, final_error([a_error, aaaa_error])}
        end
    end
  end

  defp query(domain, type, timeout_ms) do
    {name, class, type, opts, deadline} = query_args(domain, type, timeout_ms)

    case :inet_res.resolve(name, class, type, opts, deadline) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, classify_error(reason)}
    end
  end

  @doc false
  # The arguments of `:inet_res.resolve/5`: `timeout` is the first retransmission
  # interval (the second one doubles it), `retry` the number of rounds, and the
  # last element the overall deadline that cuts them all short.
  @spec query_args(String.t(), atom(), pos_integer()) :: tuple()
  def query_args(domain, type, timeout_ms) do
    {absolute_name(domain), :in, type, [timeout: timeout_ms, retry: 2], timeout_ms}
  end

  @doc false
  @spec absolute_name(String.t()) :: charlist()
  def absolute_name(domain), do: String.to_charlist(String.trim_trailing(domain, ".") <> ".")

  @doc false
  # Maps the shapes `:inet_res.resolve/4` reports to this behaviour's errors.
  # An empty NOERROR answer arrives as `{:noerror, msg}`; anything that is not
  # recognisably a final answer is treated as "no answer" (`:servfail`), the
  # safe side: it is retried instead of cached.
  @spec classify_error(term()) :: :nxdomain | :no_records | :servfail | :timeout
  def classify_error(:nxdomain), do: :nxdomain
  def classify_error({:nxdomain, _message}), do: :nxdomain
  def classify_error(:noerror), do: :no_records
  def classify_error({:noerror, _message}), do: :no_records
  def classify_error(:timeout), do: :timeout
  def classify_error({:timeout, _}), do: :timeout
  def classify_error(_other), do: :servfail

  defp mx_records(message) do
    message
    |> answers(:mx)
    |> Enum.map(fn {pref, host} -> %{host: to_string(host), pref: pref} end)
  end

  defp address_query(domain, type, timeout_ms) do
    with {:ok, message} <- query(domain, type, timeout_ms) do
      case answers(message, type) do
        [] -> {:error, :no_records}
        ips -> {:ok, ips}
      end
    end
  end

  defp answers(message, type) do
    for rr <- :inet_dns.msg(message, :anlist), :inet_dns.rr(rr, :type) == type do
      :inet_dns.rr(rr, :data)
    end
  end

  # No address at all. An inconclusive query outranks a definitive one: if either
  # family went unanswered, the domain may still have addresses.
  defp final_error(errors) do
    cond do
      :timeout in errors -> :timeout
      :servfail in errors -> :servfail
      :no_records in errors -> :no_records
      true -> :nxdomain
    end
  end
end
