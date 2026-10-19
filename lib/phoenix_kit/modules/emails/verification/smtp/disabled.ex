defmodule PhoenixKit.Modules.Emails.Verification.Smtp.Disabled do
  @moduledoc """
  The stand-in `Verification.Smtp` implementation: opens no socket, ever.
  """

  @behaviour PhoenixKit.Modules.Emails.Verification.Smtp

  @impl true
  def verify(_email, _mx_hosts, _opts), do: {:error, :unavailable}
end
