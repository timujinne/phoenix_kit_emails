defmodule PhoenixKit.Modules.Emails.Verification.NoNetworkTest do
  @moduledoc """
  The rule: the server opens an SMTP connection only in the mode `local`, and
  only from one place. The server side of a remote runner hands out jobs and classifies
  the facts a runner reports; the sockets are the runner's. The built-in runner is the one
  exception, `Verification.Smtp.Direct`, and this test keeps it the only one: it fails the
  day any other file under `Verification` reaches for a socket API, the day anything but
  the built-in runner calls `Direct`, or the day `Direct` can send anything but the
  commands of the verification dialogue (above all `DATA`). (DNS goes through `:inet_res`,
  which is allowed.)
  """

  use ExUnit.Case, async: true

  @forbidden ~r/:gen_tcp|:ssl\.|:gen_smtp|:socket\.|:gen_udp|Mint\.HTTP|Finch|Req\./
  @direct "lib/phoenix_kit/modules/emails/verification/smtp/direct.ex"
  @local_runner "lib/phoenix_kit/modules/emails/verification/local_runner.ex"
  @commands ~w(EHLO HELO MAIL QUIT RCPT)

  defp files do
    Path.wildcard("lib/phoenix_kit/modules/emails/verification/**/*.ex") ++
      ["lib/phoenix_kit/modules/emails/verification.ex"]
  end

  test "no verification source file but the built-in runner's session uses a socket API" do
    assert length(files()) >= 10

    offenders =
      for file <- files() -- [@direct],
          source = File.read!(file),
          Regex.match?(@forbidden, source),
          do: file

    assert offenders == []
  end

  test "the session module is the one that does" do
    assert File.read!(@direct) =~ ":gen_tcp.connect"
  end

  test "only the built-in runner calls the session module" do
    callers =
      for file <- Path.wildcard("lib/**/*.ex") -- [@direct],
          Regex.match?(~r/Smtp\.Direct/, File.read!(file)),
          do: file

    assert callers == [@local_runner]
  end

  test "the session module sends nothing but the commands of the dialogue, never DATA" do
    source = File.read!(@direct)

    # One place writes to the socket: `command/3`.
    assert length(Regex.scan(~r/:gen_tcp\.send/, source)) == 1

    sent = for [_all, word] <- Regex.scan(~r/command\(\w+, "([A-Z]+)/, source), do: word
    assert Enum.sort(Enum.uniq(sent)) == @commands

    refute source =~ ~r/["']DATA\b/
    refute source =~ ~r/["']\s*(BDAT|VRFY|EXPN|AUTH|STARTTLS)\b/
  end
end
