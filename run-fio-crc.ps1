<#
    run-fio-crc.ps1 - drive fio-crc.fio: direct random read/write disk stress
    with CRC32C verification, using 2x logical CPUs worth of threads.

    Usage (from cmd.exe):
        powershell -ExecutionPolicy Bypass -File run-fio-crc.ps1 [-SizePerJobMB 512] [-Files 4] [-Runtime 0] [-Dir <path>]

    -SizePerJobMB : data each thread writes/verifies, in MiB      (default 512)
    -Files        : files per thread                              (default 4)
    -Jobs         : number of threads; 0 = auto (2x logical CPUs) (default 0)
    -Runtime      : seconds for the random phase; 0 = one full    (default 0)
                    size-bound pass. >0 loops the random phase for that long.
    -Dir          : test directory (created if missing)  (default .\fio-crc-data)
    -Fio          : path to fio.exe                       (default fio.exe / PATH)

    Total files on disk = Jobs * Files. Total footprint ~= Jobs * SizePerJobMB.
    Keep that below free disk space on the target volume.

    fio exits non-zero on the first CRC mismatch (verify_fatal=1). When that
    happens the full fio output is saved to fio_crc_FAIL_<timestamp>.txt in the
    current directory and the script exits with code 2 (like mempat).
#>
param(
    [int]$SizePerJobMB = 512,
    [int]$Files        = 4,
    [int]$Jobs         = 0,
    [int]$Runtime      = 0,
    [string]$Dir       = '',
    [string]$Fio       = 'fio.exe'
)

$ErrorActionPreference = 'Stop'

# 2x logical CPUs unless overridden.
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount * 2 }
if ($Files -le 0) { $Files = 1 }
if ($SizePerJobMB -le 0) { $SizePerJobMB = 512 }

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
$env:SIZE      = "${SizePerJobMB}m"
$env:NJOBS     = "$Jobs"
$env:RUNTIME   = "$Runtime"
$env:TIMEBASED = if ($Runtime -gt 0) { '1' } else { '0' }

$mode = if ($Runtime -gt 0) { "time-based, ${Runtime}s random phase" }
        else                { "single size-bound pass" }
Write-Host ("fio CRC stress: jobs={0} (2x {1} CPUs), files/job={2}, size/job={3}MB, dir={4}" -f `
    $Jobs, [Environment]::ProcessorCount, $Files, $SizePerJobMB, $Dir) -ForegroundColor Cyan
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
