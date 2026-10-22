# Helpers of the Pester suite of the SMTP runner (dot-sourced by PkSmtpRunner.Tests.ps1).
#
# Everything here runs against processes started on 127.0.0.1 with an ephemeral port:
#   fake_smtp.py  a scripted mail host (one vector's `smtp` part)
#   fake_site.py  a stand-in for the PhoenixKit site (claim and report)
# The runner is the real script, started as a child process. Nothing leaves the machine.

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
$script:RunnerScript = Join-Path $script:RepoRoot 'priv' 'smtp_runner' 'pk-smtp-runner.ps1'
$script:FakeSmtp = Join-Path $script:RepoRoot 'test' 'support' 'smtp_runner' 'fake_smtp.py'
$script:FakeSite = Join-Path $script:RepoRoot 'test' 'support' 'smtp_runner' 'fake_site.py'
$script:Token = 'pk_abcd1234_TestTokenTestTokenTestTokenTestTokenTest1'
$script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

function Get-Vectors {
    Get-Content -LiteralPath (Join-Path $script:RepoRoot 'priv' 'smtp_runner' 'test_vectors.json') -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

# Starts a python fake and returns @{ Process; Port }. The first line it prints is PORT <n>.
function Start-Fake {
    param([string]$Script, [string[]]$Arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'python3'
    foreach ($a in (@('-I', $Script) + $Arguments)) { [void]$psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $line = $process.StandardOutput.ReadLine()
    if ($line -notmatch '^PORT (\d+)$') { throw "the fake $Script did not start: '$line'" }
    @{ Process = $process; Port = [int]$Matches[1] }
}

function Stop-Fake {
    param($Fake)
    if ($Fake -and -not $Fake.Process.HasExited) {
        $Fake.Process.Kill()
        [void]$Fake.Process.WaitForExit(2000)
    }
}

function Read-Jsonl {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function ConvertTo-Hashtable {
    param($Object)
    ($Object | ConvertTo-Json -Depth 20) | ConvertFrom-Json -AsHashtable
}

# Structural equality of two JSON-ish values (maps by key, lists by position).
function Test-JsonEqual {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left -is [System.Collections.IDictionary] -and $Right -is [System.Collections.IDictionary]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        foreach ($key in $Left.Keys) {
            if (-not $Right.Contains($key)) { return $false }
            if (-not (Test-JsonEqual $Left[$key] $Right[$key])) { return $false }
        }
        return $true
    }
    if (($Left -is [System.Collections.IEnumerable]) -and ($Left -isnot [string]) -and
        ($Right -is [System.Collections.IEnumerable]) -and ($Right -isnot [string])) {
        $l = @($Left); $r = @($Right)
        if ($l.Count -ne $r.Count) { return $false }
        for ($i = 0; $i -lt $l.Count; $i++) { if (-not (Test-JsonEqual $l[$i] $r[$i])) { return $false } }
        return $true
    }
    [string]$Left -ceq [string]$Right
}

# The settings object a claim answer carries.
function New-Settings {
    param([hashtable]$Override = @{})
    $settings = [ordered]@{
        mail_from         = 'verify@sender.test'
        helo              = 'runner.example.test'
        connect_timeout_s = 2
        read_timeout_s    = 5
        max_report        = 50
        idle_poll_s       = 30
        selftest_host     = '127.0.0.1'
    }
    foreach ($key in $Override.Keys) { $settings[$key] = $Override[$key] }
    $settings
}

# A claim answer without sessions (the site stub fills those in).
function New-ClaimAnswer {
    param($Settings = (New-Settings), $Paused = $null, [string]$MinVersion = '1.0.0', [string]$SeenIp = '127.0.0.1')
    [ordered]@{ sessions = @(); seen_ip = $SeenIp; settings = $Settings; paused = $Paused; min_version = $MinVersion }
}

function New-Session {
    param([string]$Lease, [string]$Domain = 'example.test', [string[]]$Mx = @('127.0.0.1'), $Probe = $null, $Rcpt)
    [ordered]@{ lease = $Lease; domain = $Domain; mx = $Mx; probe = $Probe; rcpt = @($Rcpt) }
}

# One run of the runner against a site stub and (optionally) a fake mail host.
#   Smtp      the `smtp` script (hashtable/object) or $null: no mail host, the port is closed
#   Claim     the claim answer; Batches  sessions per claim that asks for sessions
#   OmitToken   no -Token argument (the token comes from the environment or not at all)
#   SitePrefix  the kit's URL prefix the stub serves the API under ("" or "/phoenix_kit");
#               the runner is given -Server http://127.0.0.1:<port><SitePrefix>
# Returns: Run (ExitCode, Output), Claims, Reports (the recorded requests), Commands (what the
# mail host received), SmtpPort, and Records (all requests).
function Invoke-Scenario {
    param(
        $Smtp = $null,
        $Claim = (New-ClaimAnswer),
        $Batches = @(),
        [int[]]$ClaimStatuses = @(),
        [int[]]$ReportStatuses = @(),
        [string[]]$RunnerArguments = @('-StopAfterIdle', '1'),
        [string]$SiteToken = $script:Token,
        [string]$RunnerToken = $script:Token,
        [switch]$SiteDown,
        [switch]$OmitToken,
        [string]$SitePrefix = '',
        $ServerPrefixOverride = $null,
        [string]$ServerSuffix = '',
        [int]$TimeoutSec = 90
    )
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pkrunner-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    $fakeSmtp = $null; $fakeSite = $null
    try {
        # The mail host: a scripted one, or a port that nobody listens on.
        $spec = if ($Smtp) { $Smtp } else { @{ listen = $false } }
        $specPath = Join-Path $dir 'smtp.json'
        $spec | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $specPath -Encoding UTF8
        $smtpLog = Join-Path $dir 'smtp.jsonl'
        $fakeSmtp = Start-Fake $script:FakeSmtp @('--spec', $specPath, '--log', $smtpLog)

        # The site.
        $config = [ordered]@{
            token           = $SiteToken
            prefix          = $SitePrefix
            claim           = $Claim
            session_batches = @($Batches | ForEach-Object { , @($_) })
            claim_statuses  = @($ClaimStatuses)
            report_statuses = @($ReportStatuses)
        }
        $configPath = Join-Path $dir 'site.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $record = Join-Path $dir 'site.jsonl'
        $fakeSite = Start-Fake $script:FakeSite @('--config', $configPath, '--record', $record)
        $port = $fakeSite.Port
        if ($SiteDown) { Stop-Fake $fakeSite; $fakeSite = $null }

        $serverPath = if ($null -ne $ServerPrefixOverride) { $ServerPrefixOverride } else { $SitePrefix }
        $tokenArguments = if ($OmitToken) { @() } else { @('-Token', $RunnerToken) }
        $arguments = @('-Server', "http://127.0.0.1:$port$serverPath$ServerSuffix") + $tokenArguments + @('-SmtpPort', $fakeSmtp.Port, '-TimeScale', '0.05') + $RunnerArguments
        $run = Invoke-Runner -Arguments $arguments -TimeoutSec $TimeoutSec -WorkDir $dir
        $records = Read-Jsonl $record
        [pscustomobject]@{
            Run      = $run
            Records  = $records
            Claims   = @($records | Where-Object { $_.tool -eq 'emails.claim_smtp_jobs' })
            Reports  = @($records | Where-Object { $_.tool -eq 'emails.report_smtp_results' })
            Commands = @(Read-Jsonl $smtpLog | ForEach-Object { $_.cmd })
            SmtpLog  = @(Read-Jsonl $smtpLog)
            SmtpPort = $fakeSmtp.Port
            Dir      = $dir
        }
    }
    finally {
        Stop-Fake $fakeSmtp
        Stop-Fake $fakeSite
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Runs the real script in a child pwsh, with a deadline. Output = stdout and stderr.
function Invoke-Runner {
    param([string[]]$Arguments, [int]$TimeoutSec = 90, [string]$WorkDir = ([System.IO.Path]::GetTempPath()))
    $out = Join-Path $WorkDir ('out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $err = Join-Path $WorkDir ('err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $all = @('-NoProfile', '-NonInteractive', '-File', $script:RunnerScript) + $Arguments
    $quoted = $all | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }
    $p = Start-Process -FilePath $script:Pwsh -ArgumentList $quoted -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        $p.Kill($true)
    }
    $p.WaitForExit()
    $text = (Get-Content -LiteralPath $out -Raw -Encoding UTF8) + (Get-Content -LiteralPath $err -Raw -Encoding UTF8)
    [pscustomobject]@{ ExitCode = $p.ExitCode; Output = [string]$text; TimedOut = $timedOut }
}

# The line of the self-test that starts with [LEVEL] n/4.
function Get-CheckLine {
    param([string]$Output, [string]$Number)
    $Output -split "`r?`n" | Where-Object { $_ -match ('^\[(OK|FAIL|WARN)\] ' + [regex]::Escape($Number) + ' ') } | Select-Object -First 1
}
