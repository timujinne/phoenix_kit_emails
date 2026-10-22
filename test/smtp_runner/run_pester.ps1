# Runs the Pester suite of the SMTP runner and ends with one machine-readable line:
#   PESTER-RESULT passed=N failed=N skipped=N notrun=N
# Exit code: 0 when nothing failed, 1 otherwise. Called by the ExUnit wrapper
# (test/phoenix_kit/modules/emails/verification/smtp_runner_pester_test.exs).
[CmdletBinding()]
param([string]$Filter)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
Import-Module PSScriptAnalyzer -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $PSScriptRoot 'PkSmtpRunner.Tests.ps1')
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
if ($Filter) { $config.Filter.FullName = $Filter }

$result = Invoke-Pester -Configuration $config
Write-Host ("PESTER-RESULT passed={0} failed={1} skipped={2} notrun={3}" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)
if ($result.FailedCount -gt 0 -or $result.Result -eq 'Failed') { exit 1 }
exit 0
