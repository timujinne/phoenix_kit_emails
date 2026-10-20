<#
.SYNOPSIS
PhoenixKit SMTP runner: checks mailboxes from this computer for a PhoenixKit site.

.DESCRIPTION
The site hands out small jobs (a mail domain and a few addresses); this script opens
the SMTP connections from THIS machine, asks the mail host "do you accept this
recipient?" (RCPT TO) and reports the raw answers. It never sends a message: there is
no DATA command anywhere in it. The site decides what the answers mean.

Runs on Windows PowerShell 5.1 and PowerShell 7. Needs outbound TCP port 25 and HTTPS.

.PARAMETER Server
Address of the site, https://... (http only for localhost / 127.0.0.1, for development).

.PARAMETER Token
The runner token issued in Settings -> Emails (pk_...). A token on the command line is visible
to other programs in the process list: prefer -TokenFile, or the environment variable
PK_SMTP_RUNNER_TOKEN (read when neither -Token nor -TokenFile is given), or type it when
asked (an interactive session without any of them prompts for it, the input is hidden).

.PARAMETER TokenFile
A file holding the token: plain text, or the DPAPI-encrypted file written by -Install.

.PARAMETER SelfTest
Run the checks (site and token, external IP and reverse DNS, port 25, MAIL FROM) and exit
with code 0 (no [FAIL]) or 1.

.PARAMETER Install
Windows only. Store the token encrypted (DPAPI, this user) in %LOCALAPPDATA% and register
a Task Scheduler task "PhoenixKit SMTP runner" that starts the runner when you log on.

.PARAMETER Uninstall
Windows only. Remove the task and the stored token.

.PARAMETER Concurrency
Sessions at the same time (1-20, default 4).

.PARAMETER LogFile
Also write the log to this file. E-mail addresses are masked (in***@example.com).

.EXAMPLE
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_...

.EXAMPLE
powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com -Token pk_... -SelfTest

.EXAMPLE
$env:PK_SMTP_RUNNER_TOKEN = 'pk_...'; powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Server https://example.com
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The parameters are read by the functions below, at script scope.')]
param(
    [string]$Server,
    [string]$Token,
    [string]$TokenFile,
    [switch]$SelfTest,
    [switch]$Install,
    [switch]$Uninstall,
    [ValidateRange(1, 20)]
    [int]$Concurrency = 4,
    [string]$LogFile,

    # Test hooks, hidden from completion: the port used instead of 25 (self-test and
    # sessions), stop after this many empty claims in a row, and a factor for every wait.
    [Parameter(DontShow)]
    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 25,
    [Parameter(DontShow)]
    [int]$StopAfterIdle = 0,
    [Parameter(DontShow)]
    [double]$TimeScale = 1.0
)

$ErrorActionPreference = 'Stop'

# The protocol version: equal to Verification.Runners.runner_protocol_version/0 on the site
# (a test keeps the two in step). The site refuses to hand out work to an older script.
$RunnerVersion = '1.0.0'

$TaskName = 'PhoenixKit SMTP runner'
$MaxLogBytes = 5MB

#region Output and log -----------------------------------------------------------------

# Addresses are personal data: the console and the log show in***@example.com.
function Hide-Address {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $pattern = '([A-Za-z0-9._%+\-!#$&''*/=?^`{|}~]+)@([A-Za-z0-9.\-]+)'
    [regex]::Replace($Text, $pattern, {
            param($m)
            $name = $m.Groups[1].Value
            $keep = [Math]::Min(2, $name.Length - 1)
            $name.Substring(0, $keep) + '***@' + $m.Groups[2].Value
        })
}

function Write-RunnerLog {
    param(
        [string]$Message,
        [string]$Color = 'Gray',
        [switch]$NoStamp
    )
    $masked = Hide-Address $Message
    $stamp = (Get-Date).ToString('HH:mm:ss')
    if ($NoStamp) { Write-Host $masked -ForegroundColor $Color }
    else { Write-Host ('[' + $stamp + '] ' + $masked) -ForegroundColor $Color }
    if ($script:LogPath) {
        try {
            $info = New-Object System.IO.FileInfo($script:LogPath)
            if ($info.Exists -and $info.Length -gt $MaxLogBytes) {
                Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.1') -Force
            }
            $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $masked + "`n"
            [System.IO.File]::AppendAllText($script:LogPath, $line, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { $script:LogPath = $null }
    }
}

#endregion

#region JSON and HTTP ------------------------------------------------------------------

# Own serializer: the same bytes on 5.1 and 7 (ConvertTo-Json differs between them).
function ConvertTo-JsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $Text.ToCharArray()) {
        $n = [int]$c
        switch ($n) {
            34 { [void]$sb.Append('\"') }
            92 { [void]$sb.Append('\\') }
            10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') }
            9 { [void]$sb.Append('\t') }
            default {
                if ($n -lt 32 -or $n -gt 126) { [void]$sb.Append('\u' + $n.ToString('x4')) }
                else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function ConvertTo-PkJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return ([string]$Value)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($key in $Value.Keys) {
            [void]$parts.Add((ConvertTo-JsonString ([string]$key)) + ':' + (ConvertTo-PkJson $Value[$key]))
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-PkJson $item)) }
        return '[' + ($items -join ',') + ']'
    }
    ConvertTo-JsonString ([string]$Value)
}

function Initialize-TlsProtocol {
    # .NET Framework waits for "100 Continue" before a POST body; some proxies answer 417.
    [Net.ServicePointManager]::Expect100Continue = $false
    # Windows PowerShell 5.1 (.NET Framework) defaults to old protocols: ask for TLS 1.2+.
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288
        }
        catch { Write-Verbose 'TLS 1.3 is not available here, TLS 1.2 is used.' }
    }
}

function Test-LocalHost {
    param([string]$HostName)
    $HostName -in @('localhost', '127.0.0.1', '[::1]', '::1')
}

# Returns the normalized base address (scheme://host[:port][/path]) or $null. The path is the
# kit's URL prefix (core mounts the machine API under it, e.g. https://site/phoenix_kit);
# a trailing slash, a query and a fragment are dropped.
function ConvertTo-BaseUrl {
    param([string]$Address)
    $uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri)) { return $null }
    if ($uri.UserInfo) { return $null }
    $isHttps = ($uri.Scheme -eq 'https')
    $isLocalHttp = ($uri.Scheme -eq 'http' -and (Test-LocalHost $uri.Host))
    if (-not ($isHttps -or $isLocalHttp)) { return $null }
    $uri.GetLeftPart([UriPartial]::Authority) + $uri.AbsolutePath.TrimEnd('/')
}

function Read-ResponseText {
    param($Response)
    if ($null -eq $Response) { return '' }
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($Response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    }
    catch { return '' }
    finally {
        if ($reader) { $reader.Dispose() }
        $Response.Close()
    }
}

# One POST to a tool. Always returns a hashtable: Ok, Status (0 = no answer), Data, Message.
# No Idempotency-Key header, ever: core 2.63.0 would replay the first answer of a claim.
function Invoke-PkApi {
    param([string]$Tool, $Body)
    $url = $script:BaseUrl + '/api/admin/v1/' + $Tool
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-PkJson $Body))
    $out = @{ Ok = $false; Status = 0; Data = $null; Message = '' }
    $response = $null
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json'
        $req.UserAgent = 'pk-smtp-runner/' + $RunnerVersion
        $req.Timeout = 30000
        $req.ReadWriteTimeout = 30000
        $req.KeepAlive = $false
        $req.AllowAutoRedirect = $false
        $req.Headers.Add('Authorization', 'Bearer ' + $script:ApiToken)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        $response = $req.GetResponse()
        $out.Status = [int]$response.StatusCode
        $text = Read-ResponseText $response
        $response = $null
        if ($out.Status -eq 200) {
            try { $out.Data = $text | ConvertFrom-Json; $out.Ok = $true }
            catch { $out.Message = 'the answer is not JSON' }
        }
    }
    catch [System.Net.WebException] {
        $failure = $_.Exception
        if ($failure.Response) {
            $out.Status = [int]$failure.Response.StatusCode
            $text = Read-ResponseText $failure.Response
            $out.Message = Get-ProblemText $text
        }
        else { $out.Message = $failure.Message }
    }
    catch { $out.Message = $_.Exception.Message }
    finally { if ($response) { $response.Close() } }
    if (-not $out.Ok -and $out.Status -ne 0 -and -not $out.Message) { $out.Message = 'HTTP ' + $out.Status }
    $out
}

function Get-ProblemText {
    param([string]$Text)
    try {
        $problem = $Text | ConvertFrom-Json
        if ($problem.detail) { return [string]$problem.detail }
        if ($problem.title) { return [string]$problem.title }
    }
    catch { Write-Verbose 'the error answer is not JSON' }
    ''
}

#endregion

#region SMTP (also loaded into every session's runspace) ------------------------------

# The dialogue. NEVER sends DATA: the only commands are EHLO/HELO, MAIL FROM, RCPT TO, QUIT.
$SmtpLib = {
    function Limit-Text {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        if ($Text.Length -le 512) { return $Text }
        $cut = $Text.Substring(0, 512)
        if ([char]::IsHighSurrogate($cut[511])) { $cut = $cut.Substring(0, 511) }
        $cut
    }

    function Test-Timeout {
        param($Failure)
        # The socket error sits below the IOException (and below the PowerShell wrapper of a
        # method call): walk the chain, the words of the message depend on the system language.
        for ($e = $Failure; $e; $e = $e.InnerException) {
            if ($e -is [System.Net.Sockets.SocketException]) {
                return ($e.SocketErrorCode -eq [System.Net.Sockets.SocketError]::TimedOut)
            }
        }
        $Failure.Message -match 'timed out'
    }

    # Throws 'pk:connect' when the connection cannot be made in time.
    function Open-SmtpConnection {
        param([string]$MxHost, [int]$Port, [int]$ConnectTimeoutMs, [DateTime]$Hard)
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($MxHost, $Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false)) { throw 'timeout' }
            $client.EndConnect($async)
            $client.NoDelay = $true
            $stream = $client.GetStream()
            $stream.WriteTimeout = 10000
        }
        catch {
            $client.Close()
            throw 'pk:connect'
        }
        @{ Client = $client; Stream = $stream; Buf = (New-Object 'System.Collections.Generic.List[byte]'); Hard = $Hard }
    }

    function Close-SmtpConnection {
        param($Conn)
        if ($Conn -and $Conn.Client) { try { $Conn.Client.Close() } catch { $null = $_ } }
    }

    # One line (without CRLF), waiting until $Deadline. Throws pk:timeout / pk:reset / pk:protocol.
    function Read-SmtpLine {
        param($Conn, [DateTime]$Deadline)
        $buf = $Conn.Buf
        $tmp = New-Object byte[] 2048
        while ($true) {
            $at = $buf.IndexOf([byte]10)
            if ($at -ge 0) {
                $bytes = $buf.GetRange(0, $at).ToArray()
                $buf.RemoveRange(0, $at + 1)
                return [System.Text.Encoding]::UTF8.GetString($bytes).TrimEnd("`r")
            }
            if ($buf.Count -gt 4096) { throw 'pk:protocol' }
            $limit = $Deadline
            if ($Conn.Hard -lt $limit) { $limit = $Conn.Hard }
            $left = ($limit - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { throw 'pk:timeout' }
            $Conn.Stream.ReadTimeout = [int][Math]::Max(1, [Math]::Min($left, 2000000000))
            try { $n = $Conn.Stream.Read($tmp, 0, $tmp.Length) }
            catch {
                if (Test-Timeout $_.Exception) { throw 'pk:timeout' }
                throw 'pk:reset'
            }
            if ($n -le 0) { throw 'pk:reset' }
            $chunk = New-Object byte[] $n
            [Array]::Copy($tmp, $chunk, $n)
            $buf.AddRange($chunk)
        }
    }

    # A whole reply: lines are read until the 4th character is not '-'.
    function Read-SmtpReply {
        param($Conn, [int]$TimeoutMs)
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        $texts = New-Object System.Collections.ArrayList
        $code = 0
        while ($true) {
            $line = Read-SmtpLine $Conn $deadline
            if ($line -notmatch '^[0-9]{3}([ -]|$)') { throw 'pk:protocol' }
            $code = [int]$line.Substring(0, 3)
            if ($line.Length -gt 4) { [void]$texts.Add($line.Substring(4)) } else { [void]$texts.Add('') }
            if ($line.Length -eq 3 -or $line.Substring(3, 1) -ne '-') { break }
            if ($texts.Count -ge 100) { throw 'pk:protocol' }
        }
        @{ Code = $code; Text = (Limit-Text ($texts -join "`n")) }
    }

    function Send-SmtpLine {
        param($Conn, [string]$Line)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Line + "`r`n")
        try {
            $Conn.Stream.Write($bytes, 0, $bytes.Length)
            $Conn.Stream.Flush()
        }
        catch { throw 'pk:reset' }
    }

    function Send-SmtpCommand {
        param($Conn, [string]$Line, [int]$TimeoutMs)
        Send-SmtpLine $Conn $Line
        Read-SmtpReply $Conn $TimeoutMs
    }

    function ConvertTo-ReplyEntry {
        param([string]$Key, [string]$Name, $Reply)
        $entry = [ordered]@{}
        $entry[$Key] = $Name
        $entry['code'] = $Reply.Code
        $entry['text'] = $Reply.Text
        $entry
    }

    # An address that is safe to put on an SMTP command line.
    function Test-SmtpAddress {
        param([string]$Address)
        $Address -match '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9.-]{1,255}\z'
    }

    function Get-FailureOutcome {
        param($Failure)
        switch ($Failure.Exception.Message) {
            'pk:connect' { 'connect_failed' }
            'pk:timeout' { 'timeout' }
            default { 'reset' }
        }
    }

    # One attempt at one mail host. $Greeted tells whether the host gave a usable 2xx banner.
    function Invoke-SmtpAttempt {
        param([string]$MxHost, $Session, $Cfg, [DateTime]$Hard)
        $steps = New-Object System.Collections.ArrayList
        $rcpt = New-Object System.Collections.ArrayList
        $outcome = 'answered'
        $greeted = $false
        $conn = $null
        $readMs = [int]$Cfg.ReadTimeoutMs
        try {
            $conn = Open-SmtpConnection -MxHost $MxHost -Port $Cfg.Port -ConnectTimeoutMs $Cfg.ConnectTimeoutMs -Hard $Hard
            $go = $true
            $quit = $true

            $reply = Read-SmtpReply $conn $readMs
            [void]$steps.Add((ConvertTo-ReplyEntry 'cmd' 'banner' $reply))
            if ($reply.Code -ge 200 -and $reply.Code -lt 300) { $greeted = $true } else { $go = $false; $quit = $false }

            if ($go) {
                $reply = Send-SmtpCommand $conn ('EHLO ' + $Cfg.Helo) $readMs
                if ($reply.Code -ge 500) { $reply = Send-SmtpCommand $conn ('HELO ' + $Cfg.Helo) $readMs }
                [void]$steps.Add((ConvertTo-ReplyEntry 'cmd' 'ehlo' $reply))
                if ($reply.Code -ge 300) { $go = $false; $quit = ($reply.Code -ne 421) }
            }
            if ($go) {
                $reply = Send-SmtpCommand $conn ('MAIL FROM:<' + $Cfg.MailFrom + '>') $readMs
                [void]$steps.Add((ConvertTo-ReplyEntry 'cmd' 'mail' $reply))
                if ($reply.Code -ge 300) { $go = $false; $quit = ($reply.Code -ne 421) }
            }
            if ($go -and $Session.probe -and (Test-SmtpAddress ([string]$Session.probe))) {
                $reply = Send-SmtpCommand $conn ('RCPT TO:<' + $Session.probe + '>') $readMs
                [void]$steps.Add((ConvertTo-ReplyEntry 'cmd' 'rcpt_probe' $reply))
                if ($reply.Code -eq 421) { $go = $false; $quit = $false }
            }
            if ($go) {
                foreach ($item in @($Session.rcpt)) {
                    if (-not (Test-SmtpAddress ([string]$item.email))) { continue }
                    $reply = Send-SmtpCommand $conn ('RCPT TO:<' + $item.email + '>') $readMs
                    [void]$rcpt.Add((ConvertTo-ReplyEntry 'id' ([string]$item.id) $reply))
                    if ($reply.Code -eq 421) { $quit = $false; break }
                }
            }
            if ($quit) {
                try { [void](Send-SmtpCommand $conn 'QUIT' 3000) } catch { $null = $_ }
            }
        }
        catch { $outcome = Get-FailureOutcome $_ }
        finally { Close-SmtpConnection $conn }
        @{ Outcome = $outcome; Steps = $steps; Rcpt = $rcpt; Greeted = $greeted; MxUsed = $MxHost }
    }

    # A whole leased session: at most two mail hosts, in the order given. The next host is
    # tried only when this one never gave a usable banner.
    function Invoke-SmtpSession {
        param($Session, $Cfg)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $hard = [DateTime]::UtcNow.AddMilliseconds($Cfg.HardMs)
        $attempt = $null
        $tried = 0
        foreach ($mx in @($Session.mx)) {
            if ($tried -ge 2) { break }
            $tried++
            $attempt = Invoke-SmtpAttempt -MxHost ([string]$mx) -Session $Session -Cfg $Cfg -Hard $hard
            if ($attempt.Greeted) { break }
        }
        $result = [ordered]@{}
        $result['lease'] = [string]$Session.lease
        if ($attempt) {
            $result['mx_used'] = $attempt.MxUsed
            $result['outcome'] = $attempt.Outcome
            $result['steps'] = @($attempt.Steps)
            $result['rcpt'] = @($attempt.Rcpt)
        }
        else {
            $result['mx_used'] = $null
            $result['outcome'] = 'connect_failed'
            $result['steps'] = @()
            $result['rcpt'] = @()
        }
        $result['ms'] = [int]$watch.ElapsedMilliseconds
        $result
    }

    # The self-test's port check: connect, read a banner, QUIT. State is 'open' (a 220
    # banner), 'blocked' (no connection) or 'unknown' (connected, but no usable banner).
    function Test-SmtpPort {
        param([string]$HostName, [int]$Port, [int]$ConnectTimeoutMs, [int]$ReadTimeoutMs)
        $state = @{ State = 'blocked'; Banner = ''; Detail = '' }
        $conn = $null
        try {
            $conn = Open-SmtpConnection -MxHost $HostName -Port $Port -ConnectTimeoutMs $ConnectTimeoutMs -Hard ([DateTime]::UtcNow.AddMinutes(2))
            $state.State = 'unknown'
            $reply = Read-SmtpReply $conn $ReadTimeoutMs
            $state.Banner = ([string]$reply.Code + ' ' + $reply.Text)
            if ($reply.Code -eq 220) {
                $state.State = 'open'
                try { [void](Send-SmtpCommand $conn 'QUIT' 3000) } catch { $null = $_ }
            }
        }
        catch { $state.Detail = $_.Exception.Message }
        finally { Close-SmtpConnection $conn }
        $state
    }
}
. $SmtpLib

#endregion

#region Settings from the site ---------------------------------------------------------

function Test-Helo {
    param($Name)
    if (-not ($Name -is [string]) -or $Name.Length -eq 0 -or $Name.Length -gt 255) { return $false }
    if ($Name -match '^\[[0-9]{1,3}(\.[0-9]{1,3}){3}\]\z') { return $true }
    $Name -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z'
}

# A name the machine can say about itself in EHLO: a host name, not a literal, not a number and
# not localhost.
function Test-OwnName {
    param($Name)
    (Test-Helo $Name) -and ($Name -notmatch '^\[') -and ($Name -notmatch '^[0-9.]+\z') -and -not (Test-LocalName $Name)
}

# The machine's own DNS host name (the fully qualified one when the system knows it), or $null.
# Looked up once: it does not change while the runner works.
function Get-OwnHostName {
    if ($script:OwnHostNameLooked) { return $script:OwnHostName }
    $script:OwnHostNameLooked = $true
    $name = $null
    try { $name = [System.Net.Dns]::GetHostEntry('').HostName }
    catch { Write-Verbose 'the host name is not in DNS' }
    if ($name) { $name = $name.TrimEnd('.') }
    if (-not (Test-OwnName $name)) {
        $name = [System.Environment]::MachineName
        if (-not (Test-OwnName $name)) { $name = $null }
    }
    if ($name -and $name -notmatch '\.') {
        $domain = [System.Environment]::GetEnvironmentVariable('USERDNSDOMAIN')
        if ($domain -and (Test-OwnName ($name + '.' + $domain.TrimEnd('.')))) { $name = $name + '.' + $domain.TrimEnd('.') }
    }
    $script:OwnHostName = $name
    $name
}

# The name for EHLO, in this order: the site's HELO, the reverse DNS of the external IP, the
# machine's own host name when it is fully qualified (has a dot), the literal of a PUBLIC
# address the site saw, a single-label machine name (not an FQDN, so a last resort: some mail
# servers refuse it), localhost. Never the literal of a loopback or private address.
function Resolve-Helo {
    param($Configured, $HeloAuto, $SeenIp)
    if (Test-Helo $Configured) { return $Configured }
    if (Test-Helo $HeloAuto) { return $HeloAuto }
    $own = Get-OwnHostName
    if ($own -and $own -match '\.') { return $own }
    if ($SeenIp -is [string] -and $SeenIp -match '^[0-9]{1,3}(\.[0-9]{1,3}){3}\z' -and -not (Test-LocalAddress $SeenIp)) { return ('[' + $SeenIp + ']') }
    if ($own) { return $own }
    'localhost'
}

function Get-PtrName {
    param([string]$Address)
    try {
        $name = [System.Net.Dns]::GetHostEntry($Address).HostName
        if ($name) { $name = $name.TrimEnd('.') }
        if ($name -and $name -ne $Address -and (Test-Helo $name)) { return $name }
    }
    catch { Write-Verbose 'no reverse DNS' }
    $null
}

# Whether the address the site saw is a local one (loopback, private, link-local): the site
# is on the same machine or the same network, so there is no public IP to name in EHLO.
function Test-LocalAddress {
    param($Address)
    $ip = $null
    if (-not ($Address -is [string]) -or -not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 -and $ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    if ([System.Net.IPAddress]::IsLoopback($ip)) { return $true }
    $b = $ip.GetAddressBytes()
    if ($b.Length -eq 4) {
        if ($b[0] -eq 0 -or $b[0] -eq 10) { return $true }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
        return ($b[0] -eq 169 -and $b[1] -eq 254)
    }
    if (($b[0] -band 0xFE) -eq 0xFC) { return $true }
    if ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0x80) { return $true }
    -not ($b | Where-Object { $_ -ne 0 })
}

# A reverse DNS name that is the machine's own: localhost, localhost.localdomain, x.localhost.
function Test-LocalName {
    param($Name)
    ($Name -is [string]) -and ($Name.TrimEnd('.') -match '^localhost6?(\.|\z)|\.localhost\z')
}

function Get-IntSetting {
    param($Settings, [string]$Name, [int]$Default)
    $value = $null
    if ($Settings) { $value = $Settings.$Name }
    if ($value -is [int] -or $value -is [long]) { if ($value -gt 0) { return [int]$value } }
    $Default
}

function Get-RunnerInfo {
    $os = [System.Environment]::OSVersion.VersionString + ' / PowerShell ' + $PSVersionTable.PSVersion.ToString()
    $info = [ordered]@{}
    $info['version'] = $RunnerVersion
    $info['os'] = $os.Substring(0, [Math]::Min(255, $os.Length))
    $info['name'] = [System.Environment]::MachineName
    if ($script:State.Port25) { $info['port25'] = $script:State.Port25 }
    # Once the self-test has looked, the site is told the name found or null: no name worth using.
    if ($script:State.HeloChecked) { $info['helo_auto'] = $script:State.HeloAuto }
    $info
}

function Send-Claim {
    param([int]$MaxSessions)
    $body = [ordered]@{ max_sessions = $MaxSessions; runner = (Get-RunnerInfo) }
    $answer = Invoke-PkApi 'emails.claim_smtp_jobs' $body
    if ($answer.Ok) { Read-ClaimAnswer $answer.Data }
    $answer
}

function Read-ClaimAnswer {
    param($Data)
    $s = $Data.settings
    $script:State.Settings = $s
    $script:State.MailFrom = $null
    if ($s -and $s.mail_from -is [string] -and (Test-SmtpAddress $s.mail_from)) { $script:State.MailFrom = $s.mail_from }
    $script:State.SeenIp = [string]$Data.seen_ip
    $script:State.MinVersion = [string]$Data.min_version
}

function Test-NeedsUpdate {
    param([string]$MinVersion)
    try { return ([version]$MinVersion) -gt ([version]$RunnerVersion) }
    catch { return $false }
}

#endregion

#region Self-test ----------------------------------------------------------------------

function Write-Check {
    param([string]$Level, [string]$Number, [string]$Text)
    $color = @{ OK = 'Green'; FAIL = 'Red'; WARN = 'Yellow' }[$Level]
    Write-RunnerLog -Message ('[' + $Level + '] ' + $Number + ' ' + $Text) -Color $color -NoStamp
    if ($Level -eq 'FAIL') { $script:State.Failed = $true }
}

# The four start-up checks. Sets $State (Port25, HeloAuto, Failed, Fatal) and sends
# the outcome to the site in a final heartbeat. Fatal: 'token', 'version' or $null.
function Invoke-SelfTest {
    $script:State.Failed = $false
    $script:State.Fatal = $null
    $script:State.Reachable = $false
    Write-RunnerLog -Message ('Self-test of the runner ' + $RunnerVersion + ' for ' + $script:BaseUrl) -Color Cyan -NoStamp

    # 1. The site and the token.
    $answer = Send-Claim 0
    if ($answer.Ok) {
        $script:State.Reachable = $true
        if (Test-NeedsUpdate $script:State.MinVersion) {
            $script:State.Fatal = 'version'
            Write-Check 'FAIL' '1/4' ('Runner is too old (the site wants ' + $script:State.MinVersion + ', this is ' + $RunnerVersion + ') - update the runner: download it again from Settings -> Emails / Обновите раннер: скачайте его заново в Settings -> Emails')
            return
        }
        Write-Check 'OK' '1/4' ('Site reachable over ' + ([Uri]$script:BaseUrl).Scheme.ToUpper() + ', token accepted')
    }
    elseif ($answer.Status -eq 401 -or $answer.Status -eq 403) {
        $script:State.Fatal = 'token'
        Write-Check 'FAIL' '1/4' ('Token rejected (HTTP ' + $answer.Status + ') - token revoked or wrong: issue a new one in Settings -> Emails / Токен отозван или неверен: выпустите новый в Settings -> Emails')
        return
    }
    elseif ($answer.Status -eq 0) {
        Write-Check 'FAIL' '1/4' ('Site not reachable: ' + $answer.Message + ' - check the address, the network and the HTTPS certificate / Сайт недоступен: проверьте адрес, сеть и сертификат HTTPS')
        return
    }
    else {
        $hint = 'the machine API may be off or the tools hidden: see Settings -> Emails / API сайта выключен или тулы скрыты: см. Settings -> Emails'
        if ($answer.Status -eq 404) {
            $hint = 'check the URL prefix: a site with the PhoenixKit prefix needs -Server https://host/phoenix_kit, copy the address from Settings -> Emails; or the machine API is off / проверьте префикс в адресе (-Server https://host/phoenix_kit) или API сайта выключен'
        }
        Write-Check 'FAIL' '1/4' ('Site answered HTTP ' + $answer.Status + ' at ' + $script:BaseUrl + '/api/admin/v1/emails.claim_smtp_jobs (' + $answer.Message + ') - ' + $hint)
        return
    }

    # 2. External IP and its reverse DNS. A local address (the site is on this machine or
    # network) or the name "localhost" is no EHLO name: the site is told none (helo_auto stays null).
    $ip = $script:State.SeenIp
    $script:State.HeloAuto = $null
    $script:State.HeloChecked = $true
    $localHint = ' - HELO will be this computer''s own host name; run the runner on the machine whose public IP should do the check, or set HELO in Settings -> Emails / в HELO пойдёт собственное имя этого компьютера: запустите раннер на машине, чей публичный IP должен проверять почту, либо задайте HELO в Settings -> Emails'
    if ($ip -and (Test-LocalAddress $ip)) {
        Write-Check 'WARN' '2/4' ('The site sees a local address (' + $ip + ')' + $localHint)
    }
    elseif ($ip) {
        $name = Get-PtrName $ip
        if (Test-LocalName $name) {
            Write-Check 'WARN' '2/4' ('External IP ' + $ip + ' has the reverse DNS name ' + $name + $localHint)
        }
        elseif ($name) {
            $script:State.HeloAuto = $name
            Write-Check 'OK' '2/4' ('External IP ' + $ip + ', reverse DNS ' + $name)
        }
        else {
            Write-Check 'WARN' '2/4' ('External IP ' + $ip + ' has no reverse DNS - many mail servers refuse such connections; set HELO in Settings -> Emails / У IP нет обратной записи DNS: многие почтовые серверы такие соединения отвергают, задайте HELO в настройках')
        }
    }
    else {
        Write-Check 'WARN' '2/4' 'The site did not tell the external IP - skipped / Сайт не вернул внешний IP, проверка пропущена'
    }

    # 3. Port 25 to the site's own mail host.
    $s = $script:State.Settings
    $target = $null
    if ($s -and $s.selftest_host -is [string] -and $s.selftest_host) { $target = $s.selftest_host }
    if ($target) {
        $check = Test-SmtpPort -HostName $target -Port $SmtpPort `
            -ConnectTimeoutMs ((Get-IntSetting $s 'connect_timeout_s' 20) * 1000) `
            -ReadTimeoutMs ((Get-IntSetting $s 'read_timeout_s' 30) * 1000)
        $script:State.Port25 = $check.State
        $script:State.Port25At = [DateTime]::UtcNow
        if ($check.State -eq 'open') {
            Write-Check 'OK' '3/4' ('Port 25 open: ' + $target + ' answered ' + $check.Banner)
        }
        elseif ($check.State -eq 'blocked') {
            Write-Check 'FAIL' '3/4' ('Port 25 closed (ISP/firewall) - cannot connect to ' + $target + ':' + $SmtpPort + '; ask the ISP or open outbound 25 / Порт 25 закрыт (провайдер/файрвол): исходящие соединения на порт 25 не проходят')
        }
        else {
            Write-Check 'WARN' '3/4' ('Port 25 connects but ' + $target + ' gave no 220 banner (' + $check.Banner + $check.Detail + ') - the IP may be blocked / Порт 25 открыт, но баннера 220 нет: возможно, IP в блок-листе')
        }
    }
    else {
        Write-Check 'WARN' '3/4' 'The site has no mail host to test port 25 against - skipped; set the self-test host in Settings -> Emails / Не с чем проверять порт 25, проверка пропущена'
    }

    # 4. MAIL FROM on the site.
    if ($script:State.MailFrom) {
        Write-Check 'OK' '4/4' ('MAIL FROM is set on the site: ' + $script:State.MailFrom)
    }
    else {
        Write-Check 'FAIL' '4/4' 'MAIL FROM is not set on the site - no sessions will start; set the sender address in Settings -> Emails / Не задан адрес отправителя MAIL FROM: задайте его в Settings -> Emails'
    }

    # The outcome goes to the site in the runner info of a heartbeat.
    [void](Send-Claim 0)
}

#endregion

#region Install / uninstall (Windows) --------------------------------------------------

function Test-Windows {
    [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Get-InstallDir {
    Join-Path ([System.Environment]::GetFolderPath('LocalApplicationData')) 'PhoenixKitSmtpRunner'
}

function Read-TokenFile {
    param([string]$Path)
    $text = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ($text -match '^pk_') { return $text }
    $secure = ConvertTo-SecureString -String $text
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# The token from the environment variable, so that it need not be on the command line.
function Get-TokenFromEnvironment {
    $value = [System.Environment]::GetEnvironmentVariable('PK_SMTP_RUNNER_TOKEN')
    if ($value) { return $value.Trim() }
    $null
}

# At a keyboard (not redirected, not -NonInteractive, not a service) the token is asked for
# with the input hidden; anywhere else there is nobody to ask. The conversion is the 5.1 one.
function Read-TokenFromPrompt {
    if (-not [System.Environment]::UserInteractive -or [System.Console]::IsInputRedirected) { return $null }
    try {
        $secure = Read-Host -Prompt 'Runner token (pk_..., from Settings -> Emails)' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim() }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    catch { return $null }
}

function Invoke-Uninstall {
    if (-not (Test-Windows)) {
        Write-RunnerLog -Message '-Uninstall works on Windows only (Task Scheduler and DPAPI). Nothing was changed. / Только для Windows.' -Color Red -NoStamp
        return 1
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-RunnerLog -Message ('Task "' + $TaskName + '" removed.') -Color Green -NoStamp
    }
    else { Write-RunnerLog -Message ('Task "' + $TaskName + '" was not installed.') -Color Yellow -NoStamp }
    $dir = Get-InstallDir
    if (Test-Path -LiteralPath $dir) {
        try {
            Remove-Item -LiteralPath $dir -Recurse -Force
            Write-RunnerLog -Message ('Removed ' + $dir + ' (token, script copy, log).') -Color Green -NoStamp
        }
        catch { Write-RunnerLog -Message ('Could not remove ' + $dir + ': ' + $_.Exception.Message) -Color Yellow -NoStamp }
    }
    0
}

# The token never goes to a file in the clear: ConvertFrom-SecureString without a key is DPAPI,
# readable only by this Windows user on this machine.
function Invoke-Install {
    param([string]$BaseUrl, [string]$PlainToken)
    if (-not (Test-Windows)) {
        Write-RunnerLog -Message '-Install works on Windows only (Task Scheduler and DPAPI). Nothing was changed. On other systems start the runner from your own service manager. / Только для Windows.' -Color Red -NoStamp
        return 1
    }
    if (-not $PSCommandPath) {
        Write-RunnerLog -Message 'Save the script to a file before -Install: it cannot copy itself when it is piped or pasted. Nothing was changed. / Сохраните скрипт в файл перед -Install. Ничего не изменено.' -Color Red -NoStamp
        return 1
    }

    # One claim without sessions before anything is written: a wrong or revoked token would
    # install a task that stops at every logon. A site that cannot be reached right now
    # (offline laptop) does not stop the install; the runner retries by itself.
    Initialize-TlsProtocol
    $answer = Send-Claim 0
    if ($answer.Status -eq 401 -or $answer.Status -eq 403) {
        Write-RunnerLog -Message ('Token rejected (HTTP ' + $answer.Status + ') - token revoked or wrong: issue a new one in Settings -> Emails. Nothing was installed. / Токен отозван или неверен: выпустите новый в Settings -> Emails. Ничего не установлено.') -Color Red -NoStamp
        return 1
    }
    if (-not $answer.Ok) {
        Write-RunnerLog -Message ('Warning: the site did not answer the check (' + $answer.Message + '); installing anyway. Run -SelfTest to see what is wrong. / Сайт не ответил на проверку, установка продолжается.') -Color Yellow -NoStamp
    }

    $dir = Get-InstallDir
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $tokenPath = Join-Path $dir 'token.dat'
    $scriptCopy = Join-Path $dir 'pk-smtp-runner.ps1'
    $logPath = Join-Path $dir 'runner.log'

    $secure = New-Object System.Security.SecureString
    foreach ($c in $PlainToken.ToCharArray()) { $secure.AppendChar($c) }
    $encrypted = ConvertFrom-SecureString -SecureString $secure
    [System.IO.File]::WriteAllText($tokenPath, $encrypted, [System.Text.Encoding]::ASCII)
    if ($PSCommandPath -ne $scriptCopy) { Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force }

    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $scriptCopy +
    '" -Server "' + $BaseUrl + '" -TokenFile "' + $tokenPath + '" -Concurrency ' + $Concurrency + ' -LogFile "' + $logPath + '"'
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    [void](Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description 'Checks mailboxes for a PhoenixKit site from this computer (RCPT TO only, never sends mail).' -Force)
    Start-ScheduledTask -TaskName $TaskName
    Write-RunnerLog -Message ('Installed: task "' + $TaskName + '" starts the runner when ' + $user + ' logs on, and it is running now.') -Color Green -NoStamp
    Write-RunnerLog -Message ('Token (encrypted for this user): ' + $tokenPath + '   Log: ' + $logPath) -Color Gray -NoStamp
    Write-RunnerLog -Message 'Remove it with: powershell -ExecutionPolicy Bypass -File pk-smtp-runner.ps1 -Uninstall' -Color Gray -NoStamp
    0
}

#endregion

#region The loop -----------------------------------------------------------------------

function Invoke-SessionAsync {
    param($Pool, $Session, $RunText)
    $s = $script:State.Settings
    $cfg = @{
        Port             = $SmtpPort
        Helo             = (Resolve-Helo $s.helo $script:State.HeloAuto $script:State.SeenIp)
        MailFrom         = $script:State.MailFrom
        ConnectTimeoutMs = (Get-IntSetting $s 'connect_timeout_s' 20) * 1000
        ReadTimeoutMs    = (Get-IntSetting $s 'read_timeout_s' 30) * 1000
        HardMs           = 240000
    }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $Pool
    [void]$ps.AddScript($RunText).AddArgument($Session).AddArgument($cfg)
    @{ Ps = $ps; Handle = $ps.BeginInvoke(); Lease = [string]$Session.lease; Domain = [string]$Session.domain; Count = @($Session.rcpt).Count }
}

# The result of a finished runspace, or a failed-connection result if it broke.
function Complete-Session {
    param($Job)
    $result = $null
    try {
        $out = $Job.Ps.EndInvoke($Job.Handle)
        if ($out -and $out.Count -gt 0) {
            $result = $out[$out.Count - 1].PSObject.BaseObject
        }
    }
    catch { Write-RunnerLog -Message ('Session of ' + $Job.Domain + ' failed: ' + $_.Exception.Message) -Color Yellow }
    finally { $Job.Ps.Dispose() }
    if (-not $result) {
        $result = [ordered]@{ lease = $Job.Lease; mx_used = $null; outcome = 'reset'; steps = @(); rcpt = @(); ms = 0 }
    }
    $result
}

function Show-Pause {
    param($Paused)
    if ($Paused) {
        $reason = [string]$Paused.reason
        if ($script:State.PauseShown -ne $reason) {
            $script:State.PauseShown = $reason
            if ($reason -eq 'mode_off') {
                Write-RunnerLog -Message 'SMTP verification is not set to "runner" in the site settings: nothing to do. Still sending heartbeats. / Проверка SMTP через раннер выключена в настройках сайта.' -Color Yellow
            }
            else {
                $until = ''
                if ($Paused.until) { $until = ', until ' + $Paused.until }
                Write-RunnerLog -Message ('Paused by the site: ' + $reason + $until + '. Still sending heartbeats. / Работа приостановлена сайтом.') -Color Yellow
            }
        }
    }
    elseif ($script:State.PauseShown) {
        Write-RunnerLog -Message 'The pause is over, working again. / Пауза снята.' -Color Green
        $script:State.PauseShown = $null
    }
}

# What to do after a failed API call: 'stop' (token / version) or 'retry' (wait and go on).
function Get-FailureAction {
    param($Answer, [string]$What)
    if ($Answer.Status -eq 401 -or $Answer.Status -eq 403) {
        Write-RunnerLog -Message ('Token rejected (HTTP ' + $Answer.Status + ') - token revoked or wrong: issue a new one in Settings -> Emails. Stopping. / Токен отозван или неверен: выпустите новый в Settings -> Emails.') -Color Red
        return 'stop'
    }
    Write-RunnerLog -Message ($What + ' failed: ' + $(if ($Answer.Status) { 'HTTP ' + $Answer.Status + ' ' } else { '' }) + $Answer.Message) -Color Yellow
    'retry'
}

function Step-Backoff {
    $script:State.Backoff = if ($script:State.Backoff -le 0) { 5 } else { [Math]::Min(60, $script:State.Backoff * 2) }
    $script:State.RetryAt = [DateTime]::UtcNow.AddSeconds($script:State.Backoff * $TimeScale)
}

function Clear-Backoff {
    $script:State.Backoff = 0
    $script:State.RetryAt = [DateTime]::MinValue
}

# Sends the pending results in chunks of max_report. Returns 'stop' or $null.
function Send-Report {
    $limit = Get-IntSetting $script:State.Settings 'max_report' 50
    while ($script:Pending.Count -gt 0) {
        $take = [Math]::Min($limit, $script:Pending.Count)
        $chunk = @($script:Pending.GetRange(0, $take).ToArray())
        $answer = Invoke-PkApi 'emails.report_smtp_results' ([ordered]@{ results = $chunk })
        if ($answer.Ok) {
            $script:Pending.RemoveRange(0, $take)
            Clear-Backoff
            Write-RunnerLog -Message ('Reported ' + $take + ' session(s).') -Color DarkGray
            if ($answer.Data.paused) { Show-Pause $answer.Data.paused }
        }
        elseif ($answer.Status -in @(400, 413, 422)) {
            # The site will never take this chunk: dropping it is better than sending it for ever.
            $script:Pending.RemoveRange(0, $take)
            Write-RunnerLog -Message ('The site refused a report (HTTP ' + $answer.Status + ': ' + $answer.Message + '); ' + $take + ' session(s) dropped, their leases will expire.') -Color Yellow
        }
        else {
            $action = Get-FailureAction $answer 'Report'
            if ($action -eq 'stop') { return 'stop' }
            Step-Backoff
            return $null
        }
    }
    $null
}

function Write-SessionLog {
    param($Result, $Job)
    $line = $Job.Domain + ': ' + $Result.outcome + ' via ' + $Result.mx_used + ', ' + $Job.Count + ' address(es)'
    Write-RunnerLog -Message $line -Color DarkGray
    foreach ($r in @($Result.rcpt)) {
        $item = $script:Emails[$Job.Lease + '|' + $r.id]
        if ($item) { Write-RunnerLog -Message ('  ' + $item + ' -> ' + $r.code) -Color DarkGray }
    }
    # The session is over: forget all its addresses, also the ones a short result did not name.
    $prefix = $Job.Lease + '|'
    foreach ($key in @($script:Emails.Keys)) {
        if ($key.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $script:Emails.Remove($key) }
    }
}

# Returns the exit code.
function Invoke-RunnerLoop {
    $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
    $pool.Open()
    $runText = 'param($Session, $Cfg)' + "`n" + $SmtpLib.ToString() + "`n" + 'Invoke-SmtpSession -Session $Session -Cfg $Cfg'
    $jobs = New-Object System.Collections.ArrayList
    $script:Pending = New-Object System.Collections.ArrayList
    $script:Emails = @{}
    $oldest = $null
    $lastClaim = [DateTime]::MinValue
    $nextClaim = [DateTime]::MinValue
    $nextPortCheck = [DateTime]::MaxValue
    $idleClaims = 0
    $selfTested = $false
    $code = 0
    try {
        while ($true) {
            try {
                $now = [DateTime]::UtcNow
                $stateOk = ($now -ge $script:State.RetryAt)

                # Self-test first (again, until the site has been reached once).
                if (-not $selfTested -and $stateOk) {
                    Invoke-SelfTest
                    if ($script:State.Fatal) { $code = 1; break }
                    if ($script:State.Reachable) {
                        $selfTested = $true
                        Clear-Backoff
                        if ($script:State.Port25 -eq 'blocked') { $nextPortCheck = [DateTime]::UtcNow.AddMinutes(10 * $TimeScale) }
                    }
                    else { Step-Backoff }
                    continue
                }

                # Finished sessions.
                for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
                    if ($jobs[$i].Handle.IsCompleted) {
                        $job = $jobs[$i]
                        $jobs.RemoveAt($i)
                        $result = Complete-Session $job
                        if ($script:Pending.Count -eq 0) { $oldest = [DateTime]::UtcNow }
                        [void]$script:Pending.Add($result)
                        Write-SessionLog $result $job
                        $nextClaim = [DateTime]::MinValue
                    }
                }

                # Reports: when a chunk is full, when nothing is running, or after a few seconds.
                $now = [DateTime]::UtcNow
                if ($script:Pending.Count -gt 0 -and $now -ge $script:State.RetryAt) {
                    $limit = Get-IntSetting $script:State.Settings 'max_report' 50
                    if ($script:Pending.Count -ge $limit -or $jobs.Count -eq 0 -or ($now - $oldest).TotalSeconds -ge (3 * $TimeScale)) {
                        if ((Send-Report) -eq 'stop') { $code = 1; break }
                    }
                }

                # Port 25 was closed: look again now and then.
                if ($selfTested -and $now -ge $nextPortCheck) {
                    $nextPortCheck = $now.AddMinutes(10 * $TimeScale)
                    Test-Port25Again
                    if ($script:State.Port25 -ne 'blocked') { $nextPortCheck = [DateTime]::MaxValue }
                }

                # Claim: ask for the free slots, or only say we are alive.
                $now = [DateTime]::UtcNow
                $canWork = ($script:State.Port25 -ne 'blocked') -and [bool]$script:State.MailFrom
                $slots = 0
                if ($canWork) { $slots = $Concurrency - $jobs.Count }
                $idlePoll = Get-IntSetting $script:State.Settings 'idle_poll_s' 30
                $heartbeatDue = ($now - $lastClaim).TotalSeconds -ge ($idlePoll * $TimeScale)
                if ($selfTested -and $now -ge $script:State.RetryAt -and (($slots -gt 0 -and $now -ge $nextClaim) -or $heartbeatDue)) {
                    $lastClaim = $now
                    $answer = Send-Claim $slots
                    if (-not $answer.Ok) {
                        if ((Get-FailureAction $answer 'Claim') -eq 'stop') { $code = 1; break }
                        Step-Backoff
                    }
                    else {
                        Clear-Backoff
                        if (Test-NeedsUpdate $script:State.MinVersion) {
                            Write-RunnerLog -Message ('The site needs runner ' + $script:State.MinVersion + ' or newer (this is ' + $RunnerVersion + '). Update the runner: download it again from Settings -> Emails. Stopping. / Обновите раннер: скачайте его заново в Settings -> Emails.') -Color Red
                            $code = 1
                            break
                        }
                        Show-Pause $answer.Data.paused
                        $sessions = @($answer.Data.sessions)
                        foreach ($session in $sessions) {
                            foreach ($item in @($session.rcpt)) { $script:Emails[[string]$session.lease + '|' + $item.id] = [string]$item.email }
                            [void]$jobs.Add((Invoke-SessionAsync $pool $session $runText))
                        }
                        if ($sessions.Count -gt 0) { $idleClaims = 0; $nextClaim = [DateTime]::MinValue }
                        else {
                            $idleClaims++
                            $nextClaim = [DateTime]::UtcNow.AddSeconds($idlePoll * $TimeScale)
                        }
                    }
                }

                if ($StopAfterIdle -gt 0 -and $idleClaims -ge $StopAfterIdle -and $jobs.Count -eq 0 -and $script:Pending.Count -eq 0) { break }
                Start-Sleep -Milliseconds 100
            }
            catch {
                # An odd answer or a bug must not end the runner (under -Install it would stay dead
                # after three restarts): say so, wait, go on. The hard stops are explicit breaks.
                Write-RunnerLog -Message ('Unexpected error, going on: ' + $_.Exception.Message) -Color Yellow
                Step-Backoff
                Start-Sleep -Milliseconds 100
            }
        }
    }
    finally {
        foreach ($job in $jobs) { try { $job.Ps.Stop(); $job.Ps.Dispose() } catch { $null = $_ } }
        $pool.Close()
        $pool.Dispose()
    }
    $code
}

function Test-Port25Again {
    $s = $script:State.Settings
    if (-not ($s -and $s.selftest_host)) { return }
    $check = Test-SmtpPort -HostName $s.selftest_host -Port $SmtpPort `
        -ConnectTimeoutMs ((Get-IntSetting $s 'connect_timeout_s' 20) * 1000) `
        -ReadTimeoutMs ((Get-IntSetting $s 'read_timeout_s' 30) * 1000)
    if ($check.State -ne 'blocked') {
        Write-RunnerLog -Message ('Port 25 is reachable now (' + $check.State + '), starting sessions. / Порт 25 снова доступен.') -Color Green
    }
    $script:State.Port25 = $check.State
}

#endregion

#region Main ---------------------------------------------------------------------------

function Invoke-Main {
    # .NET resolves a relative path against the process directory, PowerShell against its own
    # location: pin it down once.
    if ($LogFile) { $script:LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile) }

    if ($Uninstall) { return (Invoke-Uninstall) }

    if (-not $Server) {
        Write-RunnerLog -Message 'Missing -Server (https://your-site). Usage: pk-smtp-runner.ps1 -Server https://example.com -Token pk_... [-SelfTest | -Install | -Uninstall]' -Color Red -NoStamp
        return 2
    }
    $script:BaseUrl = ConvertTo-BaseUrl $Server
    if (-not $script:BaseUrl) {
        Write-RunnerLog -Message ('Bad -Server "' + $Server + '": use https://host (http is allowed for localhost and 127.0.0.1 only), without a user name. / Адрес сайта должен быть https://.') -Color Red -NoStamp
        return 2
    }

    # The token: -Token, else -TokenFile, else the environment variable, else (at a keyboard) a prompt.
    $plain = $Token
    if (-not $plain -and $TokenFile) {
        try { $plain = Read-TokenFile $TokenFile }
        catch {
            Write-RunnerLog -Message ('Cannot read the token file: ' + $_.Exception.Message) -Color Red -NoStamp
            return 2
        }
    }
    if (-not $plain -and -not $TokenFile) { $plain = Get-TokenFromEnvironment }
    if (-not $plain -and -not $TokenFile) { $plain = Read-TokenFromPrompt }
    if (-not $plain -or $plain -notmatch '^pk_[A-Za-z0-9_\-]+\z') {
        Write-RunnerLog -Message 'Missing or malformed token: give -Token pk_... (or -TokenFile, or set the environment variable PK_SMTP_RUNNER_TOKEN). Issue one in Settings -> Emails. / Нужен токен pk_... из Settings -> Emails (параметр -Token, -TokenFile или переменная окружения PK_SMTP_RUNNER_TOKEN).' -Color Red -NoStamp
        return 2
    }
    $script:ApiToken = $plain

    if ($Install) { return (Invoke-Install -BaseUrl $script:BaseUrl -PlainToken $plain) }

    Initialize-TlsProtocol

    if ($SelfTest) {
        Invoke-SelfTest
        if ($script:State.Failed) { return 1 } else { return 0 }
    }

    Write-RunnerLog -Message ('PhoenixKit SMTP runner ' + $RunnerVersion + ' for ' + $script:BaseUrl + ', up to ' + $Concurrency + ' session(s) at a time. Ctrl+C stops it.') -Color Cyan
    Invoke-RunnerLoop
}

$script:LogPath = $null
$script:BaseUrl = $null
$script:ApiToken = $null
$script:OwnHostName = $null
$script:OwnHostNameLooked = $false
$script:State = @{
    Port25 = $null; Port25At = $null; HeloAuto = $null; HeloChecked = $false; SeenIp = $null; MailFrom = $null; Settings = $null
    MinVersion = $null; PauseShown = $null; Backoff = 0; RetryAt = [DateTime]::MinValue
    Failed = $false; Fatal = $null; Reachable = $false
}

$exitCode = [int](@(Invoke-Main) | Select-Object -Last 1)
exit $exitCode

#endregion
