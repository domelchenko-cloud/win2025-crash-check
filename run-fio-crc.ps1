<#
.SYNOPSIS
    Drive fio-crc.fio: direct random read/write disk stress with CRC32C
    verification, using 2x logical CPUs worth of threads.

.DESCRIPTION
    fio issues random writes (each block carries a CRC32C header) and
    verify_backlog continuously reads them back to verify, so the device sees
    mixed random read/write and every read is CRC-checked. On the first mismatch
    fio aborts non-zero; this wrapper saves fio's full text output to
    fio_crc_FAIL_<timestamp>.txt in the current directory, prints it, and exits
    with code 2 (like mempat).

    Total files on disk = Jobs * Files. Footprint ~= Jobs * SizePerJobMB; keep
    that below free disk space on the target volume.

.PARAMETER SizePerJobMB
    Data each thread writes/verifies, in MiB (default 512).
.PARAMETER Files
    Files per thread (default 4).
.PARAMETER Jobs
    Number of threads; 0 = auto (2x logical CPUs) (default 0).
.PARAMETER Runtime
    Seconds for the random phase; 0 = one full size-bound pass (default 0).
.PARAMETER Dir
    Test directory, created if missing (default .\fio-crc-data).
.PARAMETER Fio
    Path to fio.exe (default fio.exe / PATH).
.PARAMETER Help
    Show usage. Also available as -h, -?, and /?.

.EXAMPLE
    .\run-fio-crc.ps1
.EXAMPLE
    .\run-fio-crc.ps1 -SizePerJobMB 1024 -Files 8
.EXAMPLE
    .\run-fio-crc.ps1 -Runtime 600 -Dir D:\fio-test
#>
param(
    [Parameter(Position = 0)][string]$SizePerJobMB = '512',
    [Parameter(Position = 1)][int]$Files = 4,
    [int]$Jobs         = 0,
    [int]$Runtime      = 0,
    [string]$Dir       = '',
    [string]$Fio       = 'fio.exe',
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

function Show-Usage {
    @'
run-fio-crc.ps1 - direct random read/write disk stress with CRC32C verification.

Usage:
  run-fio-crc.ps1 [-SizePerJobMB <MiB>] [-Files <n>] [-Jobs <n>]
                  [-Runtime <sec>] [-Dir <path>] [-Fio <path>]
  run-fio-crc.ps1 -h | -? | /?

Parameters:
  -SizePerJobMB <MiB>  Data each thread writes/verifies      (default 512)
  -Files <n>           Files per thread                      (default 4)
  -Jobs <n>            Threads; 0 = auto (2x logical CPUs)    (default 0)
  -Runtime <sec>       Random-phase seconds; 0 = one pass     (default 0)
  -Dir <path>          Test directory (created if missing)   (default .\fio-crc-data)
  -Fio <path>          Path to fio.exe                       (default fio.exe / PATH)
  -h, -?, /?           Show this help.

Examples:
  run-fio-crc.ps1
  run-fio-crc.ps1 -SizePerJobMB 1024 -Files 8
  run-fio-crc.ps1 -Runtime 600 -Dir D:\fio-test
'@ | Write-Host
}

# Help: -Help/-h bind here; -? shows comment-based help natively; /? (and a
# stray --help/help/-help) arrive as text and are matched below.
$helpTokens = @('-h', '-help', '--help', 'help', '/?', '/h', '-?', '?')
$asked = $Help -or
         ($SizePerJobMB -and ($helpTokens -contains $SizePerJobMB.ToLower())) -or
         ($Rest | Where-Object { $helpTokens -contains $_.ToLower() })
if ($asked) { Show-Usage; return }

$ErrorActionPreference = 'Stop'

# SizePerJobMB is a string (so "/?" can't fail an int cast); parse it now.
[int]$SizeMB = 512
if (-not [int]::TryParse($SizePerJobMB, [ref]$SizeMB)) {
    Write-Host "error: -SizePerJobMB must be an integer (got '$SizePerJobMB').`n" -ForegroundColor Red
    Show-Usage
    exit 1
}

# 2x logical CPUs unless overridden.
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount * 2 }
if ($Files -le 0) { $Files = 1 }
if ($SizeMB -le 0) { $SizeMB = 512 }

# Resolve the job file next to this script.
$jobFile = Join-Path $PSScriptRoot 'fio-crc.fio'
if (-not (Test-Path $jobFile)) { throw "job file not found: $jobFile" }

# Test directory: default .\fio-crc-data under the current location.
if ([string]::IsNullOrWhiteSpace($Dir)) {
    $Dir = Join-Path (Get-Location).Path 'fio-crc-data'
}
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# Where FAIL logs land (before we change directory).
$saveDir = (Get-Location).Path

# fio parameters are passed via environment (see fio-crc.fio). We cd into the
# test dir and use directory="." so Windows drive-letter colons never need the
# fio path-escaping dance.
$env:DIR       = '.'
$env:NRFILES   = "$Files"
$env:SIZE      = "${SizeMB}m"
$env:NJOBS     = "$Jobs"
$env:RUNTIME   = "$Runtime"
$env:TIMEBASED = if ($Runtime -gt 0) { '1' } else { '0' }

$mode = if ($Runtime -gt 0) { "time-based, ${Runtime}s random phase" }
        else                { "single size-bound pass" }
Write-Host ("fio CRC stress: jobs={0} (2x {1} CPUs), files/job={2}, size/job={3}MB, dir={4}" -f `
    $Jobs, [Environment]::ProcessorCount, $Files, $SizeMB, $Dir) -ForegroundColor Cyan
Write-Host ("mode: {0}. Press Ctrl+C to stop." -f $mode) -ForegroundColor Cyan

$log = Join-Path $env:TEMP ("fio_crc_{0}.log" -f [System.IO.Path]::GetRandomFileName())
$exit = 0

Push-Location $Dir
# fio writes progress AND verify-failure detail to stderr; with 2>&1 those
# become error records. Under 'Stop' that throws before we can capture/report,
# so relax it to 'Continue' just around the run.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    # Run fio; Tee-Object shows output live AND captures every line (stdout +
    # stderr) to the log so the FAIL file has fio's full text output.
    & $Fio $jobFile 2>&1 | Tee-Object -FilePath $log
    $exit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $prevEAP
    Pop-Location
}

if ($exit -eq 0) {
    Write-Host "[fio] all CRC verification passed (exit 0)." -ForegroundColor Green
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    exit 0
}

# Non-zero => a CRC mismatch (or other fatal I/O error). Preserve the evidence:
# save fio's full text output to the FAIL file AND print it to the console.
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$dest  = Join-Path $saveDir ("fio_crc_FAIL_{0}.txt" -f $stamp)

$content = ''
if (Test-Path $log) { $content = Get-Content -Raw -Path $log }
if ([string]::IsNullOrWhiteSpace($content)) {
    $content = "fio exited $exit but produced no captured output."
}
Set-Content -Path $dest -Value $content -Encoding ASCII
Remove-Item $log -Force -ErrorAction SilentlyContinue

Write-Host ("*** CRC MISMATCH / fio error (exit {0}) *** -> saved to {1}" -f $exit, $dest) `
    -ForegroundColor Red
Write-Host "----- fio output -----" -ForegroundColor Red
Write-Host $content -ForegroundColor Red
Write-Host "----- end fio output (also saved above; search for 'verify') -----" `
    -ForegroundColor Red
exit 2
