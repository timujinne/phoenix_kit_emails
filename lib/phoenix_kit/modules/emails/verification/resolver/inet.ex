defmodule PhoenixKit.Modules.Emails.Verification.Resolver.Inet do
  @moduledoc """
  `Verification.Resolver` backed by OTP's `:inet_res`.

  `:inet_res.lookup/4` flattens every failure to `[]`; `:inet_res.resolve/4` is
  used instead because the pipeline has to tell "this domain has no mail
  server" (final) from "the resolver did not answer" (try again later).
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
    case :inet_res.resolve(String.to_charlist(domain), :in, type, timeout: timeout_ms, retry: 1) do
      {:ok, message} -> {:ok, message}
      {:error, reason} -> {:error, classify_error(reason)}
    end
  end

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
