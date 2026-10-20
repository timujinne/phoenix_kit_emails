defmodule PhoenixKit.Modules.Emails.Verification.NoNetworkTest do
  @moduledoc """
  The owner's rule: nothing in this module may open a connection to an SMTP
  server, ever. The server side only hands out jobs and classifies the facts a
  runner reports; the sockets are the runner's. This test keeps it that way by
  failing the day anything under `Verification` reaches for a socket API. (DNS goes
  through `:inet_res`, which is allowed.)
  """

  use ExUnit.Case, async: true

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
end
