defmodule PhoenixKit.Modules.Emails.ApplicationIntegration do
  @moduledoc "Registers unified email provider on startup."

  def register do
    Application.put_env(:phoenix_kit, :email_provider, PhoenixKit.Modules.Emails.Provider)
  end
end
