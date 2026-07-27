<#
    run-mempat.ps1 - launch several mempat instances in the background.

    Usage (from cmd.exe):
        powershell -ExecutionPolicy Bypass -File run-mempat.ps1 <TotalMB> [PerMB] [-Zero]

    TotalMB : total megabytes to test across all instances
    PerMB   : megabytes each mempat instance examines (default 512)
    -Zero   : pass --zero to every mempat instance (zero-fill the region once
              after allocation, before the pattern cycles begin)

    Instance count = ceil(TotalMB / PerMB). Each instance runs forever with
    stride 256 and offset = index*8 (0, 8, 16, ...). mempat's default seed is
    PID-based, so every instance uses a unique pattern range.

    Each instance's output is captured to a temp file. If an instance detects
    corruption (exit code 2), its output - the MISMATCH line, expected pattern,
    offset/stride and the hex page dump - is printed to the console AND saved to
    <pid>_corrupted_page.txt in the current directory.

    Ctrl+C stops the script and kills all launched instances.
#>
param(
    [Parameter(Mandatory = $true)][int]$TotalMB,
    [int]$PerMB = 512,
    [switch]$Zero
)

if ($PerMB -le 0) { $PerMB = 512 }

$stride = 256
$exe = Join-Path $PSScriptRoot 'mempat.exe'
if (-not (Test-Path $exe)) { $exe = 'mempat.exe' }   # fall back to cwd / PATH

$count = [int][math]::Ceiling($TotalMB / $PerMB)
$procs = @()

# Handle a corrupting instance: show its captured output and save the dump.
function Save-Corruption($p) {
    $dest = Join-Path (Get-Location).Path ("{0}_corrupted_page.txt" -f $p.Id)
    $content = ''
    if ($p.LogPath -and (Test-Path $p.LogPath)) {
        $content = Get-Content -Raw -Path $p.LogPath
    }
    Set-Content -Path $dest -Value $content -Encoding ASCII
    Write-Host ("[{0}] *** CORRUPTION DETECTED *** mempat pid={1} (exit code 2) -> saved to {2}" -f `
        (Get-Date -Format HH:mm:ss), $p.Id, $dest) -ForegroundColor Red
    Write-Host $content -ForegroundColor Red
}

try {
    for ($i = 0; $i -lt $count; $i++) {
        $offset = $i * 8
        $mpArgs = @($PerMB, 0, $offset, $stride)
        if ($Zero) { $mpArgs += '--zero' }

        $log = Join-Path $env:TEMP ("mempat_{0}.log" -f [System.IO.Path]::GetRandomFileName())
        $p = Start-Process -FilePath $exe `
                -ArgumentList $mpArgs `
                -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $log
        $p | Add-Member -NotePropertyName LogPath -NotePropertyValue $log -Force
        $procs += $p
        Write-Host ("[{0}] started mempat #{1}  pid={2}  size={3}MB  offset={4}  stride={5}  zero={6}" -f `
            (Get-Date -Format HH:mm:ss), ($i + 1), $p.Id, $PerMB, $offset, $stride, [bool]$Zero)
        Start-Sleep -Seconds 1
    }

    Write-Host ("Running {0} mempat instances (~{1} MB total). Press Ctrl+C to stop." -f `
        $count, ($count * $PerMB)) -ForegroundColor Cyan

    # stay alive until Ctrl+C; flag any instance that exits on its own
    while ($true) {
        foreach ($p in $procs) {
            if ($p.HasExited -and -not $p.Reported) {
                $p | Add-Member -NotePropertyName Reported -NotePropertyValue $true -Force
                if ($p.ExitCode -eq 2) {
                    Save-Corruption $p
                } else {
                    Write-Host ("[{0}] mempat pid={1} exited (code {2})" -f `
                        (Get-Date -Format HH:mm:ss), $p.Id, $p.ExitCode) -ForegroundColor Yellow
                    if ($p.LogPath -and (Test-Path $p.LogPath)) {
                        Remove-Item $p.LogPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host "Stopping mempat instances..."
    foreach ($p in $procs) {
        try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    Get-Process mempat -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # clean up temp logs of instances that didn't report corruption
    foreach ($p in $procs) {
        if ($p.LogPath -and (Test-Path $p.LogPath) -and $p.ExitCode -ne 2) {
            Remove-Item $p.LogPath -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Done."
}
