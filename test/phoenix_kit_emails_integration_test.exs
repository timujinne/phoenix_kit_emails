defmodule PhoenixKitEmails.IntegrationTest do
  use ExUnit.Case, async: false

  test "ApplicationIntegration.register sets unified provider" do
    Application.delete_env(:phoenix_kit, :email_provider)

    PhoenixKit.Modules.Emails.ApplicationIntegration.register()

    assert Application.get_env(:phoenix_kit, :email_provider) ==
             PhoenixKit.Modules.Emails.Provider
  end
end
