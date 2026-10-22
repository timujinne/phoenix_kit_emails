defmodule PhoenixKitEmails.Test.FakeResolver do
  @moduledoc """
  A `Verification.Resolver` for tests. Answers come from the *calling
  process's* dictionary, so tests using it stay async-safe, and every lookup is
  recorded so a test can prove a cache was (or was not) hit. A domain nobody
  scripted is `:nxdomain`.

  An answer may also be a *list* of answers: they are given one per lookup, in
  order, and the last one repeats - "the first attempt fails, the second says
  nxdomain" is `mx: [{:error, :timeout}, {:error, :nxdomain}]`. A function of no
  arguments is called when the lookup is made and its return value is the answer
  (to do something at that very moment, e.g. cancel a batch in the middle of a job).
  """

  @behaviour PhoenixKit.Modules.Emails.Verification.Resolver

  @doc "Scripts the answers for `domain`: `mx:` and/or `addr:` (each an `{:ok, _}`/`{:error, _}`)."
  def put(domain, answers) do
    Process.put({__MODULE__, domain}, answers)
    for kind <- [:mx, :addr], do: Process.delete({__MODULE__, :seen, kind, domain})
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
    domain |> scripted() |> Keyword.get(kind, default) |> next_answer(kind, domain)
  end

  defp next_answer(answers, kind, domain) when is_list(answers) do
    seen = Process.get({__MODULE__, :seen, kind, domain}, 0)
    Process.put({__MODULE__, :seen, kind, domain}, seen + 1)
    Enum.at(answers, seen) || List.last(answers)
  end

  defp next_answer(answer, _kind, _domain) when is_function(answer, 0), do: answer.()
  defp next_answer(answer, _kind, _domain), do: answer

  defp scripted(domain), do: Process.get({__MODULE__, domain}, [])
end
