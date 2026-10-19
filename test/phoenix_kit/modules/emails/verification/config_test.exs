defmodule PhoenixKit.Modules.Emails.Verification.ConfigTest do
  # Not async: it changes the application env.
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Emails.Verification.Config

  setup do
    original = Application.get_env(:phoenix_kit_emails, :verification_confirm_pause_ms)

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit_emails, :verification_confirm_pause_ms, original),
        else: Application.delete_env(:phoenix_kit_emails, :verification_confirm_pause_ms)
    end)
  end

  describe "confirm_pause_ms/0" do
    test "defaults to 300" do
      Application.delete_env(:phoenix_kit_emails, :verification_confirm_pause_ms)
      assert Config.confirm_pause_ms() == 300
    end

    test "is read from the application env; zero switches the pause off" do
      Application.put_env(:phoenix_kit_emails, :verification_confirm_pause_ms, 50)
      assert Config.confirm_pause_ms() == 50

      Application.put_env(:phoenix_kit_emails, :verification_confirm_pause_ms, 0)
      assert Config.confirm_pause_ms() == 0
    end

    test "is bounded at two seconds" do
      Application.put_env(:phoenix_kit_emails, :verification_confirm_pause_ms, 60_000)
      assert Config.confirm_pause_ms() == 2_000
    end

    test "anything that is not a non-negative integer is the default" do
      for bad <- [-1, 1.5, "300", nil, :soon] do
        Application.put_env(:phoenix_kit_emails, :verification_confirm_pause_ms, bad)
        assert Config.confirm_pause_ms() == 300, inspect(bad)
      end
    end
  end
end
