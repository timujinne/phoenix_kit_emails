defmodule PhoenixKitEmails.Test.Pwsh do
  @moduledoc """
  Whether the Pester suite of the SMTP runner (`test/smtp_runner`, tag `:pwsh`) can run
  here: it needs `pwsh` (PowerShell 7), the Pester and PSScriptAnalyzer modules, and
  `python3` for the fake mail host and the fake site. `test_helper.exs` excludes the tag,
  and says why, when something is missing.
  """

  @doc "`nil` when the suite can run, otherwise the reason it cannot."
  @spec unavailable_reason() :: String.t() | nil
  def unavailable_reason do
    cond do
      is_nil(System.find_executable("pwsh")) ->
        "pwsh (PowerShell 7) is not installed"

      is_nil(System.find_executable("python3")) ->
        "python3 is not installed (the fake mail host and the fake site are Python scripts)"

      not modules_present?() ->
        "the PowerShell modules Pester and PSScriptAnalyzer are not installed " <>
          "(Install-Module Pester, PSScriptAnalyzer)"

      true ->
        nil
    end
  end

  defp modules_present? do
    script =
      "if ((Get-Module -ListAvailable Pester) -and (Get-Module -ListAvailable PSScriptAnalyzer)) " <>
        "{ exit 0 } else { exit 1 }"

    match?({_, 0}, System.cmd("pwsh", ["-NoProfile", "-NonInteractive", "-Command", script]))
  end
end
