defmodule PhoenixKit.Modules.Emails.Verification.SmtpRunnerScriptTest do
  @moduledoc """
  What can be said about `priv/smtp_runner/pk-smtp-runner.ps1` without running it
  (the Pester suite runs it: `smtp_runner_pester_test.exs`): the protocol version it
  carries is the server's, and the file is something Windows PowerShell 5.1 reads
  right.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Emails.Verification.Runners
  alias PhoenixKit.Modules.Emails.Web.RunnerScriptController

  @path "priv/smtp_runner/pk-smtp-runner.ps1"

  defp source, do: File.read!(@path)

  test "$RunnerVersion is the protocol version the server asks for" do
    assert [_, version] = Regex.run(~r/^\$RunnerVersion\s*=\s*'([^']+)'\s*$/m, source())
    assert version == Runners.runner_protocol_version()
  end

  test "the controller serves this very file" do
    assert File.read!(RunnerScriptController.script_path()) == source()
  end

  test "the file starts with a UTF-8 byte order mark and is valid UTF-8" do
    # Windows PowerShell 5.1 reads a BOM-less file as ANSI: the Russian hints would
    # turn to rubbish.
    assert <<0xEF, 0xBB, 0xBF, rest::binary>> = source()
    assert String.valid?(rest)
  end

  test "the script never sends an Idempotency-Key header" do
    # Core 2.63.0 would answer a repeated claim from its stored first answer.
    # (The one mention in a comment is allowed; a header would need the name in a string.)
    refute source() =~ ~r/Headers?\.(Add|Set)\([^)]*idempotency/i
    refute source() =~ ~r/['"]Idempotency-Key['"]/i
  end

  describe "the script has no DATA command" do
    defp code do
      source()
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
      |> Enum.join("\n")
    end

    test "no quoted DATA literal in the code, however it reaches the wire" do
      refute code() =~ ~r/['"]DATA\b/i
    end

    test "every line sent through Send-SmtpCommand starts with one of the five known commands" do
      sent =
        ~r/Send-SmtpCommand\s+\$\w+\s+\(?'([A-Z]+)/
        |> Regex.scan(code())
        |> Enum.map(fn [_, command] -> command end)
        |> Enum.uniq()
        |> Enum.sort()

      assert sent == ["EHLO", "HELO", "MAIL", "QUIT", "RCPT"]
      # Nothing but the wrapper itself sends a raw line.
      assert length(Regex.scan(~r/Send-SmtpLine\s+\$/, code())) == 1
    end
  end
end
