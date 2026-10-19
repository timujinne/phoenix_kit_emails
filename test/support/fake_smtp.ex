defmodule PhoenixKitEmails.Test.FakeSmtp do
  @moduledoc """
  A `Verification.Smtp` for tests that returns a scripted outcome (set with
  `put/1` in the calling process) and records the call. No sockets.
  """

  @behaviour PhoenixKit.Modules.Emails.Verification.Smtp

  def put(outcome), do: Process.put({__MODULE__, :outcome}, outcome)
  def calls, do: Enum.reverse(Process.get({__MODULE__, :calls}, []))

  @impl true
  def verify(email, hosts, _opts) do
    Process.put({__MODULE__, :calls}, [{email, hosts} | Process.get({__MODULE__, :calls}, [])])
    Process.get({__MODULE__, :outcome}, {:error, :unavailable})
  end
end
