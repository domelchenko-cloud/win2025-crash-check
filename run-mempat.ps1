<#
    run-mempat.ps1 - launch several mempat instances in the background.

    Usage (from cmd.exe):
        powershell -ExecutionPolicy Bypass -File run-mempat.ps1 <TotalMB> [PerMB]

    TotalMB : total megabytes to test across all instances
    PerMB   : megabytes each mempat instance examines (default 512)

    Instance count = ceil(TotalMB / PerMB). Each instance runs forever with
    stride 256 and offset = index*8 (0, 8, 16, ...). mempat's default seed is
    PID-based, so every instance uses a unique pattern range.

    Ctrl+C stops the script and kills all launched instances.
#>
param(
    [Parameter(Mandatory = $true)][int]$TotalMB,
    [int]$PerMB = 512
)

if ($PerMB -le 0) { $PerMB = 512 }

$stride = 256
$exe = Join-Path $PSScriptRoot 'mempat.exe'
if (-not (Test-Path $exe)) { $exe = 'mempat.exe' }   # fall back to cwd / PATH

$count = [int][math]::Ceiling($TotalMB / $PerMB)
$procs = @()

try {
    for ($i = 0; $i -lt $count; $i++) {
        $offset = $i * 8
        $p = Start-Process -FilePath $exe `
                -ArgumentList @($PerMB, 0, $offset, $stride) `
                -PassThru -WindowStyle Hidden
        $procs += $p
        Write-Host ("[{0}] started mempat #{1}  pid={2}  size={3}MB  offset={4}  stride={5}" -f `
            (Get-Date -Format HH:mm:ss), ($i + 1), $p.Id, $PerMB, $offset, $stride)
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
                    Write-Host ("[{0}] *** CORRUPTION DETECTED *** mempat pid={1} (exit code 2)" -f `
                        (Get-Date -Format HH:mm:ss), $p.Id) -ForegroundColor Red
                } else {
                    Write-Host ("[{0}] mempat pid={1} exited (code {2})" -f `
                        (Get-Date -Format HH:mm:ss), $p.Id, $p.ExitCode) -ForegroundColor Yellow
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
    Write-Host "Done."
}
