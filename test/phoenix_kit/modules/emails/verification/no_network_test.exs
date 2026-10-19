defmodule PhoenixKit.Modules.Emails.Verification.NoNetworkTest do
  @moduledoc """
  The owner's rule for this stage: nothing here may open a connection to an SMTP
  server, ever. The SMTP step is a behaviour whose only implementation is a stub;
  this test keeps it that way by failing the day anything under `Verification`
  reaches for a socket API. (DNS goes through `:inet_res`, which is allowed.)
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Smtp.Disabled

  @forbidden ~r/:gen_tcp|:ssl\.|:gen_smtp|:socket\.|:gen_udp|Mint\.HTTP|Finch|Req\./

  test "no verification source file uses a socket or HTTP client API" do
    files =
      Path.wildcard("lib/phoenix_kit/modules/emails/verification/**/*.ex") ++
        ["lib/phoenix_kit/modules/emails/verification.ex"]

    assert length(files) >= 10

    offenders =
      for file <- files, source = File.read!(file), Regex.match?(@forbidden, source), do: file

    assert offenders == []
  end

  test "the default SMTP client declines every request" do
    assert {:error, :unavailable} = Disabled.verify("a@example.com", ["mx.example.com"], [])
  end
end
