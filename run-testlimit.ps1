<#
    run-testlimit.ps1 - repeatedly fill a target amount of memory with
    Sysinternals Testlimit in bursts (start -> wait -> kill -> restart).

    Usage (from cmd.exe):
        powershell -ExecutionPolicy Bypass -File run-testlimit.ps1 <TotalMB> [WaitSeconds]

    TotalMB     : megabytes to fill/check each burst
    WaitSeconds : seconds to let each burst run before killing it (default 5)

    Each burst runs:  testlimit64.exe -accepteula -d 512 -c <ceil(TotalMB/512)>
    (-d 512 = allocate and touch 512 MB chunks; -c = number of chunks needed
    to reach TotalMB). Loops forever; killing a burst frees its memory before
    the next one starts. Ctrl+C stops the loop and kills any running instance.

    Keep testlimit64.exe in this folder or on PATH. If your Testlimit build
    rejects -accepteula, remove it below and accept the EULA once by running
    testlimit64.exe manually.
#>
param(
    [Parameter(Mandatory = $true)][int]$TotalMB,
    [int]$WaitSeconds = 5
)

$chunkMB = 512
$chunks  = [int][math]::Ceiling($TotalMB / $chunkMB)
if ($chunks -lt 1) { $chunks = 1 }

$exe    = 'testlimit64.exe'                             # resolved via cwd / PATH
$tlArgs = @('-accepteula', '-d', $chunkMB, '-c', $chunks)

Write-Host ("testlimit: {0} {1}  (~{2} MB per burst, wait {3}s, then kill and restart)" -f `
    $exe, ($tlArgs -join ' '), ($chunks * $chunkMB), $WaitSeconds) -ForegroundColor Cyan

try {
    $n = 0
    while ($true) {
        $n++
        $p = Start-Process -FilePath $exe -ArgumentList $tlArgs -PassThru -WindowStyle Hidden
        Write-Host ("[{0}] burst {1} started  pid={2}" -f (Get-Date -Format HH:mm:ss), $n, $p.Id)

        Start-Sleep -Seconds $WaitSeconds

        if (-not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Write-Host ("[{0}] burst {1} killed" -f (Get-Date -Format HH:mm:ss), $n)
        } else {
            Write-Host ("[{0}] burst {1} exited early (code {2})" -f `
                (Get-Date -Format HH:mm:ss), $n, $p.ExitCode) -ForegroundColor Yellow
        }
    }
}
finally {
    Write-Host "Stopping testlimit..."
    Get-Process testlimit64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host "Done."
}
