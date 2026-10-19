defmodule PhoenixKitEmails.Test.FakeResolver do
  @moduledoc """
  A `Verification.Resolver` for tests. Answers come from the *calling
  process's* dictionary, so tests using it stay async-safe, and every lookup is
  recorded so a test can prove a cache was (or was not) hit. A domain nobody
  scripted is `:nxdomain`.
  """

  @behaviour PhoenixKit.Modules.Emails.Verification.Resolver

  @doc "Scripts the answers for `domain`: `mx:` and/or `addr:` (each an `{:ok, _}`/`{:error, _}`)."
  def put(domain, answers) do
    Process.put({__MODULE__, domain}, answers)
    :ok
  end

  @doc "Lookups made so far in this process, oldest first: `{:mx | :addr, domain}`."
  def calls, do: Enum.reverse(Process.get({__MODULE__, :calls}, []))

  @impl true
  def lookup_mx(domain, _timeout), do: answer(:mx, domain, {:error, :nxdomain})

  @impl true
  def lookup_addresses(domain, _timeout), do: answer(:addr, domain, {:error, :nxdomain})

  defp answer(kind, domain, default) do
    Process.put({__MODULE__, :calls}, [{kind, domain} | Process.get({__MODULE__, :calls}, [])])
    domain |> scripted() |> Keyword.get(kind, default)
  end

  defp scripted(domain), do: Process.get({__MODULE__, domain}, [])
end
