defmodule PhoenixKit.Modules.Emails.Verification.SmtpRunnerPesterTest do
  @moduledoc """
  Runs the Pester suite of the SMTP runner (`test/smtp_runner/PkSmtpRunner.Tests.ps1`)
  under `pwsh`: the real script, started as a child process, against a scripted fake mail
  host and a stub of the site, both on 127.0.0.1 with an ephemeral port (every shared test
  vector is replayed; PSScriptAnalyzer with the Windows PowerShell 5.1 compatibility rules
  runs on the script). No real SMTP server, no live site.

  Tagged `:pwsh`: `test_helper.exs` excludes it, and prints why, when `pwsh`, `python3`
  or the Pester / PSScriptAnalyzer modules are missing; `mix test --exclude pwsh` skips it
  on purpose. It takes a couple of minutes.
  """

  # Not async: the suite starts many processes and has timing in it (a one second read
  # timeout); it should not compete with the other tests.
  use ExUnit.Case, async: false

  @moduletag :pwsh
  @moduletag timeout: 900_000

  test "the Pester suite passes" do
    {output, status} =
      System.cmd(
        "pwsh",
        ["-NoProfile", "-NonInteractive", "-File", "test/smtp_runner/run_pester.ps1"],
        stderr_to_stdout: true,
        env: [{"NO_COLOR", "1"}]
      )

    counts =
      Regex.named_captures(
        ~r/PESTER-RESULT passed=(?<passed>\d+) failed=(?<failed>\d+) skipped=\d+ notrun=(?<notrun>\d+)/,
        output
      )

    assert counts, "the Pester run printed no summary:\n#{output}"
    passed = String.to_integer(counts["passed"])
    failed = String.to_integer(counts["failed"])
    notrun = String.to_integer(counts["notrun"])

    assert failed == 0 and status == 0, "Pester failed:\n#{failures(output)}"
    assert notrun == 0
    # The suite replays 13 vectors four times each, plus the self-test and loop checks.
    assert passed >= 80
  end

  defp failures(output) do
    output
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.take(-120)
    |> Enum.join("\n")
  end
end
