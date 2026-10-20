# Pester suite of priv/smtp_runner/pk-smtp-runner.ps1 - the real script, started as a child
# process, against a scripted fake mail host and a stub of the site, both on 127.0.0.1.
# No real SMTP server is ever contacted. Run by `mix test` (tag :pwsh) or directly:
#   pwsh -File test/smtp_runner/run_pester.ps1

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:VectorCases = @((Get-Vectors).vectors | ForEach-Object { @{ Name = $_.name } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers.ps1')
    $script:Doc = Get-Vectors
    $script:Source = Get-Content -LiteralPath $script:RunnerScript -Raw -Encoding UTF8

    # The runner's own view of the claim it makes while looping.
    function Get-LoopClaims($Scenario) {
        # The first two claims are the self-test's (a plain heartbeat each).
        @($Scenario.Claims | Select-Object -Skip 2)
    }
    function Get-Rcpt($Id, $Local, $Domain = 'example.test') {
        [ordered]@{ id = $Id; email = "$Local@$Domain" }
    }
}

Describe 'the script as a file' {
    It 'parses without errors' {
        $errors = $null; $tokens = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:RunnerScript, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'has no findings of PSScriptAnalyzer, including the 5.1 compatibility rules' {
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $findings = @(Invoke-ScriptAnalyzer -Path $script:RunnerScript -Settings $settings)
        ($findings | ForEach-Object { "$($_.RuleName) line $($_.Line): $($_.Message)" }) | Should -BeNullOrEmpty
    }

    It 'the compatibility check is not vacuous: it flags what Windows PowerShell 5.1 lacks' {
        $probe = Join-Path $TestDrive 'newer.ps1'
        Set-Content -LiteralPath $probe -Value '$x = $null ?? 1; Get-Error; "a" | ConvertFrom-Json -AsHashtable'
        $settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
        $rules = @(Invoke-ScriptAnalyzer -Path $probe -Settings $settings).RuleName | Sort-Object -Unique
        $rules | Should -Contain 'PSUseCompatibleSyntax'
        $rules | Should -Contain 'PSUseCompatibleCommands'
    }

    It 'declares the protocol version' {
        $script:Source | Should -Match "(?m)^\`$RunnerVersion = '1\.0\.0'\s*$"
    }

    It 'has no ForEach-Object -Parallel, ConvertFrom-Json -AsHashtable or -SkipCertificateCheck (7-only features)' {
        $script:Source | Should -Not -Match 'ForEach-Object\s+-Parallel'
        $script:Source | Should -Not -Match 'ConvertFrom-Json[^\n]*-AsHashtable'
        $script:Source | Should -Not -Match 'SkipCertificateCheck'
    }
}

Describe 'the site address with a path (the kit URL prefix)' {
    BeforeAll {
        $script:Accepting = @{
            banner = @('220 mx.example.test ESMTP ready')
            rules  = @(
                @{ match = '^EHLO '; reply = @('250 mx.example.test') }
                @{ match = '^MAIL FROM:'; reply = @('250 2.1.0 Ok') }
                @{ match = '^RCPT TO:'; reply = @('250 2.1.5 Ok') }
                @{ match = '^QUIT'; reply = @('221 2.0.0 Bye'); then = 'close' }
            )
        }
    }

    It 'posts under the path of -Server, in the self-test and in the loop' {
        $session = New-Session -Lease 'lease-p' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Accepting -Batches @(, @($session)) -SitePrefix '/phoenix_kit'
        $s.Run.ExitCode | Should -Be 0
        $s.Run.Output | Should -Not -Match 'HTTP 404'
        $s.Run.Output | Should -Match 'for http://127\.0\.0\.1:\d+/phoenix_kit,'
        $s.Records.Count | Should -BeGreaterThan 2
        foreach ($record in $s.Records) {
            $record.path | Should -Be "/phoenix_kit/api/admin/v1/$($record.tool)"
            $record.status | Should -Be 200
        }
        @($s.Reports).Count | Should -Be 1
    }

    It 'tolerates a trailing slash and ignores a query or fragment' {
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -SitePrefix '/phoenix_kit' -RunnerArguments @('-SelfTest') -ServerSuffix '/?x=1#top'
        $s.Run.ExitCode | Should -Be 0
        foreach ($record in $s.Records) { $record.path | Should -Be "/phoenix_kit/api/admin/v1/$($record.tool)" }
    }

    It 'still works for a site at the root' {
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -RunnerArguments @('-SelfTest')
        foreach ($record in $s.Records) { $record.path | Should -Be "/api/admin/v1/$($record.tool)" }
    }

    It 'says what to check on a 404: the URL prefix, the address it tried' {
        # The site answers under /phoenix_kit; the runner is told the bare address.
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -SitePrefix '/phoenix_kit' -ServerPrefixOverride '' -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        $line = Get-CheckLine $s.Run.Output '1/4'
        $line | Should -Match '^\[FAIL\] 1/4 Site answered HTTP 404'
        $line | Should -Match 'URL prefix'
        $line | Should -Match '127\.0\.0\.1:\d+/api/admin/v1/emails\.claim_smtp_jobs'
    }
}

Describe 'the arguments' {
    It 'asks for a site address' {
        $run = Invoke-Runner -Arguments @('-Token', $script:Token)
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'Missing -Server'
    }

    It 'refuses http for a site that is not on this machine' {
        $run = Invoke-Runner -Arguments @('-Server', 'http://example.com', '-Token', $script:Token)
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'https'
    }

    It 'refuses a user name in the address' {
        $run = Invoke-Runner -Arguments @('-Server', 'https://user:pw@example.com', '-Token', $script:Token)
        $run.ExitCode | Should -Be 2
    }

    It 'asks for a token' {
        $run = Invoke-Runner -Arguments @('-Server', 'https://example.com')
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'token'
    }

    It 'refuses a token with odd characters (it goes into a header)' {
        $run = Invoke-Runner -Arguments @('-Server', 'https://example.com', '-Token', 'pk_abc;def')
        $run.ExitCode | Should -Be 2
    }

    It 'limits -Concurrency to 1..20' {
        $run = Invoke-Runner -Arguments @('-Server', 'https://example.com', '-Token', $script:Token, '-Concurrency', '0')
        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'Concurrency'
    }

    It 'reads the token from a plain -TokenFile when there is no -Token' {
        $file = Join-Path $TestDrive 'token2.txt'
        Set-Content -LiteralPath $file -Value "  $($script:Token)  "
        $dir = Join-Path $TestDrive 'tf'
        [void](New-Item -ItemType Directory -Path $dir)
        $specPath = Join-Path $dir 'smtp.json'
        '{"banner":["220 mx ESMTP"],"rules":[]}' | Set-Content -LiteralPath $specPath
        $config = [ordered]@{ token = $script:Token; claim = (New-ClaimAnswer) }
        $configPath = Join-Path $dir 'site.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        $smtp = Start-Fake $script:FakeSmtp @('--spec', $specPath, '--log', (Join-Path $dir 'smtp.jsonl'))
        $site = Start-Fake $script:FakeSite @('--config', $configPath, '--record', (Join-Path $dir 'site.jsonl'))
        try {
            $run = Invoke-Runner -Arguments @('-Server', "http://127.0.0.1:$($site.Port)", '-TokenFile', $file, '-SelfTest', '-SmtpPort', $smtp.Port)
            $run.ExitCode | Should -Be 0
            $run.Output | Should -Match '\[OK\] 1/4'
        }
        finally { Stop-Fake $smtp; Stop-Fake $site }
    }

    It 'guards -Install with a clear message off Windows' -Skip:($IsWindows) {
        $run = Invoke-Runner -Arguments @('-Server', 'https://example.com', '-Token', $script:Token, '-Install')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'Windows only'
        $run.Output | Should -Match 'Nothing was changed'
    }

    It 'guards -Uninstall with a clear message off Windows' -Skip:($IsWindows) {
        $run = Invoke-Runner -Arguments @('-Uninstall')
        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'Windows only'
    }
}

Describe 'the log file' {
    It 'is resolved against the PowerShell location, not the process directory' {
        $sub = Join-Path $TestDrive 'elsewhere'
        [void](New-Item -ItemType Directory -Path $sub)
        $configPath = Join-Path $TestDrive 'site-log.json'
        [ordered]@{ token = $script:Token; claim = (New-ClaimAnswer) } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath
        $site = Start-Fake $script:FakeSite @('--config', $configPath, '--record', (Join-Path $TestDrive 'site-log.jsonl'))
        try {
            $command = "Set-Location -LiteralPath '$sub'; & '$($script:RunnerScript)' -Server http://127.0.0.1:$($site.Port) -Token $($script:Token) -SmtpPort 9 -StopAfterIdle 1 -TimeScale 0.05 -LogFile relative.log"
            $out = & $script:Pwsh -NoProfile -NonInteractive -Command $command 2>&1
            $LASTEXITCODE | Should -Be 0
            (Join-Path $sub 'relative.log') | Should -Exist
        }
        finally { Stop-Fake $site }
    }
}

Describe 'the check for a local address' {
    BeforeAll {
        # The real functions of the script, without running the script.
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunnerScript, [ref]$tokens, [ref]$errors)
        foreach ($name in 'Test-LocalAddress', 'Test-LocalName') {
            $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($found.Extent.Text))
        }
    }

    It 'calls <Ip> local' -ForEach @(
        @{ Ip = '127.0.0.1' }, @{ Ip = '127.9.9.9' }, @{ Ip = '::1' }, @{ Ip = '10.0.0.1' }, @{ Ip = '10.255.255.255' },
        @{ Ip = '172.16.0.1' }, @{ Ip = '172.31.255.255' }, @{ Ip = '192.168.0.1' }, @{ Ip = '169.254.1.1' },
        @{ Ip = 'fc00::1' }, @{ Ip = 'fdff::1' }, @{ Ip = 'fe80::1' }, @{ Ip = 'febf::1' }, @{ Ip = '::ffff:10.1.1.1' }, @{ Ip = '::' }
    ) {
        Test-LocalAddress $Ip | Should -BeTrue
    }

    It 'calls <Ip> public' -ForEach @(
        @{ Ip = '8.8.8.8' }, @{ Ip = '11.0.0.1' }, @{ Ip = '172.15.255.255' }, @{ Ip = '172.32.0.1' }, @{ Ip = '192.167.0.1' },
        @{ Ip = '192.169.0.1' }, @{ Ip = '169.253.1.1' }, @{ Ip = '203.0.113.7' }, @{ Ip = '2001:db8::1' }, @{ Ip = 'fe00::1' },
        @{ Ip = 'fec0::1' }, @{ Ip = '2a00:1450::1' }, @{ Ip = '::ffff:8.8.8.8' }
    ) {
        Test-LocalAddress $Ip | Should -BeFalse
    }

    It 'is not fooled by what is no address' -ForEach @(@{ Value = $null }, @{ Value = '' }, @{ Value = 'host.example' }, @{ Value = 42 }) {
        Test-LocalAddress $Value | Should -BeFalse
    }

    It 'knows the name localhost' {
        Test-LocalName 'localhost' | Should -BeTrue
        Test-LocalName 'LOCALHOST.' | Should -BeTrue
        Test-LocalName 'localhost.localdomain' | Should -BeTrue
        Test-LocalName 'localhost6.localdomain6' | Should -BeTrue
        Test-LocalName 'a.localhost' | Should -BeTrue
        Test-LocalName 'mx.example.test' | Should -BeFalse
        Test-LocalName 'notlocalhost' | Should -BeFalse
        Test-LocalName $null | Should -BeFalse
    }
}

Describe 'the name for EHLO' {
    BeforeAll {
        # The real functions of the script, without running the script. The machine's own
        # name is replaced by a stub: what it is depends on the machine.
        $errors = $null; $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RunnerScript, [ref]$tokens, [ref]$errors)
        foreach ($name in 'Test-Helo', 'Test-LocalAddress', 'Test-LocalName', 'Test-OwnName', 'Resolve-Helo') {
            $found = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($found.Extent.Text))
        }
        function Get-OwnHostName { $global:PkTestOwnName }
    }

    AfterAll { Remove-Variable -Name PkTestOwnName -Scope Global -ErrorAction SilentlyContinue }

    It 'takes the HELO of the site first, then the reverse DNS name' {
        $global:PkTestOwnName = 'ws.corp.example'
        Resolve-Helo 'runner.example.test' 'ptr.example.net' '203.0.113.9' | Should -Be 'runner.example.test'
        Resolve-Helo $null 'ptr.example.net' '203.0.113.9' | Should -Be 'ptr.example.net'
    }

    It 'uses the machine name, not a literal, when the site sees <Ip>' -ForEach @(
        @{ Ip = '127.0.0.1' }, @{ Ip = '10.1.2.3' }, @{ Ip = '172.16.0.9' }, @{ Ip = '192.168.1.5' }, @{ Ip = '169.254.1.1' }
    ) {
        $global:PkTestOwnName = 'ws.corp.example'
        Resolve-Helo $null $null $Ip | Should -Be 'ws.corp.example'
    }

    It 'prefers the machine name to the literal of a public address without a reverse name' {
        $global:PkTestOwnName = 'ws.corp.example'
        Resolve-Helo $null $null '203.0.113.9' | Should -Be 'ws.corp.example'
    }

    It 'falls back to the literal of a PUBLIC address when the machine has no name' {
        $global:PkTestOwnName = $null
        Resolve-Helo $null $null '203.0.113.9' | Should -Be '[203.0.113.9]'
    }

    It 'never makes a literal of <Ip>, even when nothing else is left' -ForEach @(
        @{ Ip = '127.0.0.1' }, @{ Ip = '10.1.2.3' }, @{ Ip = '192.168.1.5' }, @{ Ip = '169.254.1.1' }, @{ Ip = '::1' }, @{ Ip = $null }
    ) {
        $global:PkTestOwnName = $null
        Resolve-Helo $null $null $Ip | Should -Be 'localhost'
    }

    It 'accepts only a real host name as the machine name' {
        Test-OwnName 'ws.corp.example' | Should -BeTrue
        Test-OwnName 'WORKSTATION' | Should -BeTrue
        foreach ($bad in 'localhost', 'localhost.localdomain', '[127.0.0.1]', '127.0.0.1', '', $null, 'bad name') {
            Test-OwnName $bad | Should -BeFalse
        }
    }
}

Describe 'the self-test' {
    It 'passes: four [OK] lines, exit 0, and the outcome goes to the site' {
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx.example.test ESMTP ready'); rules = @() } -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 0
        (Get-CheckLine $s.Run.Output '1/4') | Should -Match '^\[OK\]'
        (Get-CheckLine $s.Run.Output '2/4') | Should -Match '^\[(OK|WARN)\]'
        (Get-CheckLine $s.Run.Output '3/4') | Should -Match '^\[OK\] 3/4 Port 25 open: 127\.0\.0\.1 answered 220'
        (Get-CheckLine $s.Run.Output '4/4') | Should -Match '^\[OK\] 4/4 MAIL FROM'
        $s.Run.Output | Should -Not -Match '\[FAIL\]'

        # First the plain claim (max_sessions 0), last the same with what was found out.
        $s.Claims.Count | Should -Be 2
        $s.Claims[0].body.max_sessions | Should -Be 0
        $info = $s.Claims[1].body.runner
        $s.Claims[1].body.max_sessions | Should -Be 0
        $info.version | Should -Be '1.0.0'
        $info.port25 | Should -Be 'open'
        $info.name | Should -Not -BeNullOrEmpty
        $info.os | Should -Match 'PowerShell 7'
        $s.Claims[0].body.runner.PSObject.Properties.Name | Should -Not -Contain 'port25'
        $s.Reports.Count | Should -Be 0
    }

    It 'WARNs, with a hint in both languages, when the site sees a local address, and sends helo_auto null' -ForEach @(
        @{ Ip = '127.0.0.1' }, @{ Ip = '::1' }, @{ Ip = '10.1.2.3' }, @{ Ip = '192.168.1.5' }
    ) {
        $claim = New-ClaimAnswer -SeenIp $Ip
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx.example.test ESMTP ready'); rules = @() } -Claim $claim -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 0
        $line = Get-CheckLine $s.Run.Output '2/4'
        $line | Should -Match ('^\[WARN\] 2/4 The site sees a local address \(' + [regex]::Escape($Ip) + '\)')
        $line | Should -Match 'HELO would be the local name; run the runner on the machine whose public IP should do the check, or set HELO in Settings -> Emails'
        $line | Should -Match 'запустите раннер'
        $s.Run.Output | Should -Not -Match '\[FAIL\]'

        # The first claim does not know yet; the one with the outcome says null, not "localhost".
        $s.Claims[0].body.runner.PSObject.Properties.Name | Should -Not -Contain 'helo_auto'
        $s.Claims[1].body.runner.PSObject.Properties.Name | Should -Contain 'helo_auto'
        $s.Claims[1].body.runner.helo_auto | Should -BeNullOrEmpty
    }

    It 'keeps helo_auto null in the claims of the loop too' {
        $claim = New-ClaimAnswer -SeenIp '192.168.1.5'
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -Claim $claim
        $loop = @(Get-LoopClaims $s)
        $loop.Count | Should -BeGreaterThan 0
        foreach ($c in $loop) {
            $c.body.runner.PSObject.Properties.Name | Should -Contain 'helo_auto'
            $c.body.runner.helo_auto | Should -BeNullOrEmpty
        }
    }

    It 'sends only what the claim schema accepts' {
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -RunnerArguments @('-SelfTest')
        $allowed = @('version', 'os', 'name', 'helo_auto', 'port25')
        foreach ($claim in $s.Claims) {
            ($claim.body.PSObject.Properties.Name | Sort-Object) | Should -Be @('max_sessions', 'runner')
            foreach ($name in $claim.body.runner.PSObject.Properties.Name) { $allowed | Should -Contain $name }
        }
    }

    It 'never sends an Idempotency-Key header, always the bearer token and JSON' {
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -RunnerArguments @('-SelfTest')
        foreach ($record in $s.Records) {
            $record.headers.PSObject.Properties.Name | Should -Not -Contain 'idempotency-key'
            $record.headers.authorization | Should -Be "Bearer $($script:Token)"
            $record.headers.'content-type' | Should -Match '^application/json'
        }
    }

    It 'FAILs with the reason when the token is revoked or wrong (401)' {
        $s = Invoke-Scenario -RunnerToken 'pk_wrongwrong_xxxxxxxx' -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '1/4') | Should -Match '^\[FAIL\] 1/4 Token rejected \(HTTP 401\) - token revoked or wrong: issue a new one in Settings -> Emails'
    }

    It 'FAILs when port 25 is closed and reports it as blocked' {
        $s = Invoke-Scenario -Smtp $null -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '3/4') | Should -Match '^\[FAIL\] 3/4 Port 25 closed \(ISP/firewall\)'
        $s.Claims[-1].body.runner.port25 | Should -Be 'blocked'
    }

    It 'FAILs when the site has no MAIL FROM' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ mail_from = $null })
        $s = Invoke-Scenario -Smtp @{ banner = @('220 mx ESMTP'); rules = @() } -Claim $claim -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '4/4') | Should -Match '^\[FAIL\] 4/4 MAIL FROM is not set on the site'
    }

    It 'WARNs, and still exits 0, when there is no host to test port 25 against' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ selftest_host = $null })
        $s = Invoke-Scenario -Claim $claim -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 0
        (Get-CheckLine $s.Run.Output '3/4') | Should -Match '^\[WARN\] 3/4'
    }

    It 'WARNs when port 25 connects but the banner is not 220' {
        $s = Invoke-Scenario -Smtp @{ banner = @('554 5.7.1 go away'); banner_then = 'close'; rules = @() } -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 0
        (Get-CheckLine $s.Run.Output '3/4') | Should -Match '^\[WARN\] 3/4 Port 25 connects but'
        $s.Claims[-1].body.runner.port25 | Should -Be 'unknown'
    }

    It 'FAILs when the site is not reachable' {
        $s = Invoke-Scenario -SiteDown -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '1/4') | Should -Match '^\[FAIL\] 1/4 Site not reachable'
    }

    It 'FAILs with a hint when the site answers with another error' {
        $s = Invoke-Scenario -ClaimStatuses @(404) -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '1/4') | Should -Match '^\[FAIL\] 1/4 Site answered HTTP 404'
    }

    It 'FAILs when the site wants a newer runner' {
        $s = Invoke-Scenario -Claim (New-ClaimAnswer -MinVersion '2.0.0') -RunnerArguments @('-SelfTest')
        $s.Run.ExitCode | Should -Be 1
        (Get-CheckLine $s.Run.Output '1/4') | Should -Match 'update the runner'
    }

    It 'hints in Russian as well' {
        $s = Invoke-Scenario -Smtp $null -RunnerArguments @('-SelfTest')
        (Get-CheckLine $s.Run.Output '3/4') | Should -Match 'Порт 25 закрыт'
    }
}

Describe 'a session against the scripted mail host: <Name>' -ForEach $script:VectorCases {
    BeforeAll {
        $vector = @($script:Doc.vectors | Where-Object { $_.name -eq $Name })[0]
        $defaults = $script:Doc.defaults
        $override = @{}
        foreach ($p in $defaults.settings.PSObject.Properties) { $override[$p.Name] = $p.Value }
        if ($vector.PSObject.Properties.Name -contains 'settings') {
            foreach ($p in $vector.settings.PSObject.Properties) { $override[$p.Name] = $p.Value }
        }
        $mx = if ($vector.PSObject.Properties.Name -contains 'mx') { $vector.mx } else { $defaults.mx }
        $probe = if ($vector.PSObject.Properties.Name -contains 'probe') { $vector.probe } else { $null }
        $session = New-Session -Lease $vector.report.lease -Domain $defaults.domain -Mx $mx -Probe $probe -Rcpt $vector.rcpt
        $script:Scenario = Invoke-Scenario -Smtp $vector.smtp -Claim (New-ClaimAnswer -Settings (New-Settings $override)) -Batches @(, @($session))
        $script:Vector = $vector
    }

    It 'exits cleanly and reports exactly one session' {
        $script:Scenario.Run.TimedOut | Should -BeFalse
        $script:Scenario.Run.ExitCode | Should -Be 0
        $script:Scenario.Reports.Count | Should -Be 1
        $script:Scenario.Reports[0].body.results.Count | Should -Be 1
    }

    It 'reports what the vector expects' {
        $actual = ConvertTo-Hashtable $script:Scenario.Reports[0].body.results[0]
        $expected = ConvertTo-Hashtable $script:Vector.report
        # The time it took is not part of the contract, only that it is a number.
        $actual['ms'] | Should -BeOfType [long]
        $actual['ms'] | Should -BeGreaterOrEqual 0
        $actual.Remove('ms')
        $same = Test-JsonEqual $actual $expected
        if (-not $same) { Write-Host ("ACTUAL:   " + ($actual | ConvertTo-Json -Depth 10 -Compress)); Write-Host ("EXPECTED: " + ($expected | ConvertTo-Json -Depth 10 -Compress)) }
        $same | Should -BeTrue
    }

    It 'sends the commands of the vector, in order, and never DATA' {
        # The self-test's port check connects too (and only says QUIT): the session's commands follow it.
        $commands = @($script:Scenario.Commands | Where-Object { $_ })
        $commands | Should -Not -Contain 'DATA'
        ($commands | Where-Object { $_ -match '^DATA' }) | Should -BeNullOrEmpty
        $own = @($commands | Select-Object -Skip 1)
        if ($script:Vector.commands.Count -eq 0) { $own | Should -BeNullOrEmpty }
        else { ($own -join "`n") | Should -Be (@($script:Vector.commands) -join "`n") }
    }

    It 'tells the site about itself in the claim, with no Idempotency-Key' {
        $loop = Get-LoopClaims $script:Scenario
        $loop[0].body.max_sessions | Should -Be 4
        foreach ($record in $script:Scenario.Records) {
            $record.headers.PSObject.Properties.Name | Should -Not -Contain 'idempotency-key'
        }
    }
}

Describe 'the loop' {
    BeforeAll {
        $script:Normal = @{
            banner = @('220 mx.example.test ESMTP ready')
            rules  = @(
                @{ match = '^EHLO '; reply = @('250 mx.example.test') }
                @{ match = '^MAIL FROM:'; reply = @('250 2.1.0 Ok') }
                @{ match = '^RCPT TO:'; reply = @('250 2.1.5 Ok') }
                @{ match = '^QUIT'; reply = @('221 2.0.0 Bye'); then = 'close' }
            )
        }
        function New-Sessions($Count) {
            1..$Count | ForEach-Object { New-Session -Lease "lease-$_" -Domain "d$_.test" -Rcpt @((Get-Rcpt "r$_" 'info' "d$_.test")) }
        }
    }

    It 'keeps sending heartbeats but claims no sessions while port 25 is closed' {
        $s = Invoke-Scenario -Smtp $null -RunnerArguments @('-StopAfterIdle', '2')
        $s.Run.ExitCode | Should -Be 0
        $s.Claims.Count | Should -BeGreaterOrEqual 4
        foreach ($claim in $s.Claims) { $claim.body.max_sessions | Should -Be 0 }
        $s.Reports.Count | Should -Be 0
        $s.Run.Output | Should -Match '\[FAIL\] 3/4 Port 25 closed'
    }

    It 'claims no sessions while MAIL FROM is missing' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ mail_from = $null })
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -RunnerArguments @('-StopAfterIdle', '2')
        foreach ($c in $s.Claims) { $c.body.max_sessions | Should -Be 0 }
    }

    It 'prints a pause once and goes on with heartbeats' {
        $paused = [ordered]@{ reason = 'too many blocks'; until = '2026-10-20T20:00:00Z' }
        $s = Invoke-Scenario -Smtp $script:Normal -Claim (New-ClaimAnswer -Paused $paused) -RunnerArguments @('-StopAfterIdle', '3')
        $s.Run.ExitCode | Should -Be 0
        ([regex]::Matches($s.Run.Output, 'Paused by the site: too many blocks')).Count | Should -Be 1
        (Get-LoopClaims $s).Count | Should -BeGreaterOrEqual 3
    }

    It 'says when the site is not in runner mode' {
        $s = Invoke-Scenario -Smtp $script:Normal -Claim (New-ClaimAnswer -Paused ([ordered]@{ reason = 'mode_off'; until = $null })) -RunnerArguments @('-StopAfterIdle', '2')
        ([regex]::Matches($s.Run.Output, 'not set to "runner"')).Count | Should -Be 1
    }

    It 'stops with a message when the token is revoked while running (401)' {
        $s = Invoke-Scenario -Smtp $script:Normal -ClaimStatuses @(200, 200, 401) -RunnerArguments @('-StopAfterIdle', '5')
        $s.Run.ExitCode | Should -Be 1
        $s.Run.Output | Should -Match 'token revoked or wrong: issue a new one'
        $s.Claims.Count | Should -Be 3
    }

    It 'stops with a message when the site wants a newer runner' {
        $s = Invoke-Scenario -Smtp $script:Normal -Claim (New-ClaimAnswer -MinVersion '1.0.1') -RunnerArguments @('-StopAfterIdle', '5')
        $s.Run.ExitCode | Should -Be 1
        $s.Run.Output | Should -Match 'Update the runner|update the runner'
        $s.Claims.Count | Should -Be 1
    }

    It 'backs off and tries again after a server error' {
        $s = Invoke-Scenario -Smtp $script:Normal -ClaimStatuses @(200, 200, 503) -RunnerArguments @('-StopAfterIdle', '1')
        $s.Run.ExitCode | Should -Be 0
        $s.Run.Output | Should -Match 'Claim failed: HTTP 503'
        (Get-LoopClaims $s).Count | Should -BeGreaterOrEqual 2
    }

    It 'keeps a report it could not deliver and sends it again' {
        $session = New-Session -Lease 'lease-r' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @($session)) -ReportStatuses @(503)
        $s.Run.ExitCode | Should -Be 0
        $s.Reports.Count | Should -Be 2
        $s.Reports[0].status | Should -Be 503
        $s.Reports[1].status | Should -Be 200
        $s.Reports[1].body.results[0].lease | Should -Be 'lease-r'
    }

    It 'drops a report the site refuses for good (422) instead of sending it for ever' {
        $session = New-Session -Lease 'lease-x' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @($session)) -ReportStatuses @(422)
        $s.Reports.Count | Should -Be 1
        $s.Run.Output | Should -Match 'refused a report'
        $s.Run.ExitCode | Should -Be 0
    }

    It 'reports in chunks of max_report' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ max_report = 2 })
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -Batches @(, @(New-Sessions 3))
        $s.Run.ExitCode | Should -Be 0
        $leases = @($s.Reports | ForEach-Object { $_.body.results } | ForEach-Object { $_.lease } | Sort-Object)
        $leases | Should -Be @('lease-1', 'lease-2', 'lease-3')
        foreach ($report in $s.Reports) { $report.body.results.Count | Should -BeLessOrEqual 2 }
    }

    It 'asks for no more sessions than -Concurrency' {
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @(New-Sessions 2)) -RunnerArguments @('-StopAfterIdle', '1', '-Concurrency', '2')
        foreach ($c in (Get-LoopClaims $s)) { $c.body.max_sessions | Should -BeLessOrEqual 2 }
        (Get-LoopClaims $s)[0].body.max_sessions | Should -Be 2
        $s.Reports.Count | Should -BeGreaterOrEqual 1
    }

    It 'runs the sessions side by side, not one after the other' {
        $slow = @{
            banner = @('220 mx.example.test ESMTP ready')
            rules  = @(
                @{ match = '^EHLO '; reply = @('250 mx.example.test') }
                @{ match = '^MAIL FROM:'; reply = @('250 2.1.0 Ok') }
                @{ match = '^RCPT TO:'; reply = @('250 2.1.5 Ok'); delay = 1.0 }
                @{ match = '^QUIT'; reply = @('221 2.0.0 Bye'); then = 'close' }
            )
        }
        $s = Invoke-Scenario -Smtp $slow -Batches @(, @(New-Sessions 4))
        $s.Run.ExitCode | Should -Be 0
        # Connection 1 is the self-test's port check. With four sessions at once all four EHLOs
        # arrive before the first of them has had its RCPT answered and said QUIT.
        $sessions = @($s.SmtpLog | Where-Object { $_.conn -gt 1 })
        $firstQuit = [array]::FindIndex($sessions, [Predicate[object]] { param($e) $e.cmd -eq 'QUIT' })
        @($sessions[0..($firstQuit - 1)] | Where-Object { $_.cmd -match '^EHLO' }).Count | Should -Be 4
        $s.Reports.Count | Should -BeGreaterOrEqual 1
    }

    It 'masks addresses in the output and in the log file' {
        $log = Join-Path $TestDrive 'runner.log'
        $session = New-Session -Lease 'lease-m' -Rcpt @((Get-Rcpt 'r1' 'info'), (Get-Rcpt 'r2' 'sales'))
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @($session)) -RunnerArguments @('-StopAfterIdle', '1', '-LogFile', $log)
        $s.Run.ExitCode | Should -Be 0
        $text = Get-Content -LiteralPath $log -Raw
        $text | Should -Match 'in\*\*\*@example\.test'
        $text | Should -Match 'sa\*\*\*@example\.test'
        $text | Should -Not -Match 'info@example\.test'
        $text | Should -Not -Match 'sales@example\.test'
        $s.Run.Output | Should -Not -Match 'info@example\.test'
        $s.Run.Output | Should -Match 'in\*\*\*@example\.test'
    }

    It 'cuts reply texts to 512 characters' {
        $long = '5.1.1 ' + ('x' * 900)
        $spec = @{
            banner = @('220 mx.example.test ESMTP ready')
            rules  = @(
                @{ match = '^EHLO '; reply = @('250 mx.example.test') }
                @{ match = '^MAIL FROM:'; reply = @('250 2.1.0 Ok') }
                @{ match = '^RCPT TO:'; reply = @("550 $long") }
                @{ match = '^QUIT'; reply = @('221 2.0.0 Bye'); then = 'close' }
            )
        }
        $session = New-Session -Lease 'lease-long' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $spec -Batches @(, @($session))
        $text = $s.Reports[0].body.results[0].rcpt[0].text
        $text.Length | Should -Be 512
        $text | Should -Match '^5\.1\.1 x+$'
    }

    It 'does not put an address with a line break on the wire' {
        $bad = [ordered]@{ id = 'bad'; email = "a@example.test`r`nDATA" }
        $session = New-Session -Lease 'lease-i' -Rcpt @($bad, (Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @($session))
        ($s.Commands | Where-Object { $_ -match 'DATA' }) | Should -BeNullOrEmpty
        $s.Reports[0].body.results[0].rcpt.Count | Should -Be 1
        $s.Reports[0].body.results[0].rcpt[0].id | Should -Be 'r1'
    }

    It 'does not put an address with a trailing line feed on the wire' {
        # In .NET a '$' also matches before a final LF: the guard has to use \z.
        $bad = [ordered]@{ id = 'bad'; email = "a@example.test`n" }
        $session = New-Session -Lease 'lease-lf' -Rcpt @($bad, (Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Batches @(, @($session))
        ($s.Commands | Where-Object { $_ -match '^RCPT TO:<a@' }) | Should -BeNullOrEmpty
        $s.Reports[0].body.results[0].rcpt.Count | Should -Be 1
        $s.Reports[0].body.results[0].rcpt[0].id | Should -Be 'r1'
    }

    It 'takes the site HELO, else works one out that is safe on the wire' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ helo = $null })
        $session = New-Session -Lease 'lease-h' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -Batches @(, @($session))
        $ehlo = @($s.Commands | Where-Object { $_ -match '^EHLO ' })
        $ehlo.Count | Should -Be 1
        $ehlo[0] | Should -Match '^EHLO [A-Za-z0-9.-]+$'
    }

    It 'sends the machine name in EHLO, not a literal, when the site sees <Ip> and has no HELO' -ForEach @(
        @{ Ip = '127.0.0.1' }, @{ Ip = '10.1.2.3' }, @{ Ip = '192.168.1.5' }
    ) {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ helo = $null }) -SeenIp $Ip
        $session = New-Session -Lease 'lease-h4' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -Batches @(, @($session))
        $ehlo = @($s.Commands | Where-Object { $_ -match '^EHLO ' })
        $ehlo.Count | Should -Be 1
        $ehlo[0] | Should -Not -Match '^EHLO \['
        $ehlo[0] | Should -Not -Match ([regex]::Escape($Ip))

        # What the machine calls itself: its DNS name, else the short one.
        $own = $null
        try { $own = [System.Net.Dns]::GetHostEntry('').HostName.TrimEnd('.') } catch { $own = $null }
        if (-not $own -or $own -match '^localhost' -or $own -match '^[0-9.]+$') { $own = [System.Environment]::MachineName }
        $ehlo[0] | Should -Match ('^EHLO ' + [regex]::Escape($own) + '(\.[A-Za-z0-9.-]+)?$')
    }

    It 'ignores a HELO from the site with a trailing line feed' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ helo = "runner.example.test`n" })
        $session = New-Session -Lease 'lease-h3' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -Batches @(, @($session))
        $ehlo = @($s.Commands | Where-Object { $_ -match '^EHLO ' })
        $ehlo.Count | Should -Be 1
        $ehlo[0] | Should -Not -Match 'runner\.example\.test'
    }

    It 'ignores a HELO from the site that is not a host name' {
        $claim = New-ClaimAnswer -Settings (New-Settings @{ helo = "evil.example.test`r`nDATA" })
        $session = New-Session -Lease 'lease-h2' -Rcpt @((Get-Rcpt 'r1' 'info'))
        $s = Invoke-Scenario -Smtp $script:Normal -Claim $claim -Batches @(, @($session))
        ($s.Commands | Where-Object { $_ -match 'DATA|evil' }) | Should -BeNullOrEmpty
    }
}
