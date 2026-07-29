<#
.SYNOPSIS
    Repeatedly fill a target amount of memory with Sysinternals Testlimit in
    bursts (start -> wait -> kill -> restart).

.DESCRIPTION
    Each burst runs:  testlimit64.exe -accepteula -d 512 -c <ceil(TotalMB/512)>
    (-d 512 = allocate and touch 512 MB chunks; -c = number of chunks needed to
    reach TotalMB). Loops forever; killing a burst frees its memory before the
    next one starts. Ctrl+C stops the loop and kills any running instance.

    Keep testlimit64.exe in this folder or on PATH. If your Testlimit build
    rejects -accepteula, remove it below and accept the EULA once by running
    testlimit64.exe manually.

.PARAMETER TotalMB
    MiB to fill/check each burst (required).
.PARAMETER WaitSeconds
    Seconds to let each burst run before killing it (default 5).
.PARAMETER Help
    Show usage. Also available as -h, -?, and /?.

.EXAMPLE
    .\run-testlimit.ps1 4096
.EXAMPLE
    .\run-testlimit.ps1 4096 10
#>
param(
    [Parameter(Position = 0)][string]$TotalMB,
    [Parameter(Position = 1)][int]$WaitSeconds = 5,
    [Alias('h')][switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

function Show-Usage {
    @'
run-testlimit.ps1 - fill memory in bursts with Sysinternals Testlimit.

Usage:
  run-testlimit.ps1 <TotalMB> [WaitSeconds]
  run-testlimit.ps1 -h | -? | /?

Parameters:
  <TotalMB>       MiB to fill/check each burst (required).
  [WaitSeconds]   Seconds each burst runs before it is killed (default 5).
  -h, -?, /?      Show this help.

Examples:
  run-testlimit.ps1 4096
  run-testlimit.ps1 4096 10
'@ | Write-Host
}

# Help: -Help/-h bind here; -? shows comment-based help natively; /? (and a
# stray --help/help/-help) arrive as text and are matched below.
$helpTokens = @('-h', '-help', '--help', 'help', '/?', '/h', '-?', '?')
$asked = $Help -or
         ($TotalMB -and ($helpTokens -contains $TotalMB.ToLower())) -or
         ($Rest | Where-Object { $helpTokens -contains $_.ToLower() })
if ($asked) { Show-Usage; return }

# TotalMB is a string (so "/?" can't fail an int cast); validate it now.
[int]$TotalMBInt = 0
if (-not $TotalMB -or -not [int]::TryParse($TotalMB, [ref]$TotalMBInt) -or $TotalMBInt -le 0) {
    Write-Host "error: <TotalMB> is required and must be a positive integer.`n" -ForegroundColor Red
    Show-Usage
    exit 1
}

$chunkMB = 512
$chunks  = [int][math]::Ceiling($TotalMBInt / $chunkMB)
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
