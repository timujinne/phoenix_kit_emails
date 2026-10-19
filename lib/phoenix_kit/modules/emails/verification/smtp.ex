defmodule PhoenixKit.Modules.Emails.Verification.Smtp do
  @moduledoc """
  The SMTP RCPT probe, as a behaviour.

  The pipeline only calls it when `email_verify_smtp_enabled` is on, and it
  calls whatever `Verification.Config.smtp_client/0` names. Until a real client
  exists that is `Smtp.Disabled`, which never touches the network - so turning
  the setting on cannot, by itself, open a connection to anyone's port 25.
  """

  @type outcome :: %{
          status: :valid | :invalid | :temp | :not_sure,
          reason: String.t(),
          catch_all: boolean() | nil
        }

  @doc """
  Probes `email` against its mail hosts (preferred first).

  `{:error, :unavailable}` means no probe was possible; the pipeline then
  reports `not_sure` / `smtp_unavailable`.
  """
  @callback verify(email :: String.t(), mx_hosts :: [String.t()], opts :: keyword()) ::
              {:ok, outcome()} | {:error, term()}
end
