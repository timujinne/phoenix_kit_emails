defmodule PhoenixKit.Modules.Emails.Verification.Smtp.DirectPublicOnlyTest do
  @moduledoc """
  With the test guard (`:verification_smtp_loopback_only`) switched off, a mail host named by
  an MX record must still never be dialled when it resolves to a non-public address. The
  guard is application env, so this runs on its own (`async: false`) and puts it back.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Emails.Verification.Smtp.Direct
  alias PhoenixKitEmails.Test.FakeSmtpServer

  @fake_host %{
    "banner" => ["220 mx.example.test ESMTP ready"],
    "rules" => [
      %{"match" => "^EHLO ", "reply" => ["250 mx.example.test"]},
      %{"match" => "^QUIT", "reply" => ["221 2.0.0 Bye"], "then" => "close"}
    ]
  }

  setup do
    Application.put_env(:phoenix_kit_emails, :verification_smtp_loopback_only, false)

    on_exit(fn ->
      Application.put_env(:phoenix_kit_emails, :verification_smtp_loopback_only, true)
    end)
  end

  test "a host that resolves to the loopback interface is not connected to" do
    server = FakeSmtpServer.start(@fake_host)

    session = %{
      lease: "lease-x",
      domain: "example.test",
      mx: ["localhost"],
      probe: nil,
      rcpt: [%{id: "r1", email: "info@example.test"}]
    }

    settings = %{mail_from: "verify@sender.test", helo: "runner.example.test"}

    assert {:ok, %{"outcome" => "connect_failed", "steps" => []}} =
             Direct.run(session, settings, port: server.port)

    assert FakeSmtpServer.connections(server) == 0
  end
end
