# Settings of the static check of priv/smtp_runner/pk-smtp-runner.ps1 (run by the
# Pester suite, test/smtp_runner/PkSmtpRunner.Tests.ps1).
#
# The script must run on Windows PowerShell 5.1 and PowerShell 7, and 5.1 is not
# available where it is developed, so the two compatibility rules stand in for it:
#   PSUseCompatibleSyntax   no syntax newer than 5.1 (??, ?:, &&, ||, ...)
#   PSUseCompatibleCommands no cmdlet or parameter missing from Windows PowerShell 5.1
#                           (Windows 10 / Server 2019, build 17763)
#   PSUseCompatibleTypes    no .NET type or member missing from there
@{
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning')

    ExcludeRules        = @(
        # A console tool: Write-Host is its user interface (colours, no pipeline output).
        'PSAvoidUsingWriteHost'
    )

    Rules               = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }

        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
