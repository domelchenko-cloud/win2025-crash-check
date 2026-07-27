# win2025-crash-check

Small Windows tool to stress and verify memory / pagefile integrity on Windows
Server 2025 guests, used to reproduce and detect corruption (or VM crashes)
under memory pressure.

`mempat` allocates memory in 4 KiB-page granularity, writes an incrementing
64-bit pattern across every page, then reads the whole region back and reports
any value that doesn't match what was written. Because each cycle writes fresh
values and re-reads the entire area, running with an area larger than physical
RAM forces continuous **read and write** traffic through `pagefile.sys` — the
round trip is exactly where silent corruption shows up.

## How it works

- One `VirtualAlloc` region of private, committed memory (pagefile-backed),
  sliced into 4 KiB pages.
- **Write pass:** page *i* is filled with the `uint64` value `base + i`,
  written at byte `offset` within the page and repeated every `stride` bytes.
  The value increments by 1 per page.
- **Check pass:** the whole area is read back and each slot compared to its
  expected value. On the first mismatch it prints the location (`cycle /
  page / offset / address / expected / got`), then **dumps the whole failing
  page in hex** (preceded by the expected pattern, start offset and stride) and
  **exits immediately with code 2**; a clean cycle prints `cycle N ... ok`.
- After each cycle `base` advances by the page count, so the pattern keeps
  climbing across the whole run. Arithmetic is plain `uint64` and **wraps
  cleanly** (the check uses identical arithmetic, so it stays correct on wrap).
- **Unique per process:** the default seed is `PID << 40`, so two concurrent
  instances write disjoint value ranges. If one process ever reads another's
  data (bad physical-page sharing, hypervisor/RAM fault), the value won't match
  its own expected sequence.
- Exit code is `0` when clean and `2` when any mismatch was detected — so it
  can gate CI or scripted runs.

## Usage

```
mempat.exe [MB] [iters] [offset] [stride] [seed] [--zero]
```

| Arg      | Meaning                                   | Default        |
|----------|-------------------------------------------|----------------|
| `MB`     | Total area to allocate, in MiB            | `256`          |
| `iters`  | Number of cycles (`0` = run forever)      | `0`            |
| `offset` | Start byte offset of the pattern in a page| `0`            |
| `stride` | Bytes between `uint64` slots within a page| `8` (dense)    |
| `seed`   | Pattern base value (`0x...` accepted)     | `PID << 40`    |
| `--zero` | Zero-fill the whole region once after allocation, before the pattern cycles | off |

`--zero` may appear anywhere on the command line; the positional args keep
their order regardless.

Examples:

```bat
mempat.exe 256                 :: 256 MB, forever, dense, PID-based seed
mempat.exe 7000 100 0 64       :: ~7 GB, 100 cycles, one u64 per 64 B (cache-line spacing)
mempat.exe 512 0 0 8 0xABCD00  :: explicit seed for reproducible / coordinated runs
```

On an 8 GB VM, an area of ~7 GB drives heavy bidirectional paging; stop a
forever-run with `Ctrl+C`.

### Preventing windows system to detect mempat.exe as trojan

```powershell
Add-MpPreference -ExclusionPath 'C:\Users\Administrator\Downloads'
Add-MpPreference -ExclusionProcess 'mempat.exe'
```

## Running many instances (`run-mempat.ps1`)

`run-mempat.ps1` launches several `mempat` instances in the background to
spread the load. It takes two arguments — the **total** MiB to test and the
MiB **per instance** (default 512) — and starts `ceil(TotalMB / PerMB)`
instances (stride 256, offset stepping +8 each, unique PID-based seed). It
prints a line as each one starts, then stays alive until `Ctrl+C`, at which
point it kills every instance. Add `-Zero` to pass `--zero` to every instance.

Each instance's output is captured to a temp file. If an instance detects
corruption (exit code 2), its full output — the `MISMATCH` line, expected
pattern, offset/stride and the hex page dump — is printed to the console in red
**and** saved to `<pid>_corrupted_page.txt` in the current directory. Temp
files of instances that finish cleanly are removed.

Keep `mempat.exe` in the same folder as the script (it's also found via the
current dir / `PATH`).

**PowerShell:**

```powershell
.\run-mempat.ps1 4096            # test 4096 MiB in 512 MiB chunks (8 instances)
.\run-mempat.ps1 4096 1024       # test 4096 MiB in 1024 MiB chunks (4 instances)
.\run-mempat.ps1 4096 1024 -Zero # same, but zero-fill each region first
```

If the script was downloaded (Mark-of-the-Web) and is blocked, either
`Unblock-File .\run-mempat.ps1` or `Set-ExecutionPolicy -Scope Process Bypass`
first.

**cmd.exe:**

```cmd
powershell -ExecutionPolicy Bypass -File run-mempat.ps1 4096
powershell -ExecutionPolicy Bypass -File run-mempat.ps1 4096 1024
```

The `-ExecutionPolicy Bypass` form also avoids the download/execution-policy
block. `Ctrl+C` stops the script and its instances either way.

## Filling memory with Testlimit (`run-testlimit.ps1`)

`run-testlimit.ps1` uses Sysinternals **Testlimit** to fill a target amount of
memory in repeated bursts — useful for driving commit/pagefile pressure
alongside (or instead of) `mempat`. It takes the **total** MiB to fill and an
optional **wait** in seconds (default 5), and runs, in a forever loop:

```
testlimit64.exe -accepteula -d 512 -c <ceil(TotalMB/512)>
```

`-d 512` allocates and touches 512 MiB chunks; `-c` is the chunk count needed
to reach the target (rounded up to the 512 MiB granularity). Each burst runs
for `WaitSeconds`, is killed (freeing its memory), and restarted. `Ctrl+C`
stops the loop and kills any running instance.

`testlimit64.exe` must be in the same folder or on `PATH` (it is a separate
[Sysinternals](https://learn.microsoft.com/sysinternals/downloads/testlimit)
download, not part of this repo). If your build rejects `-accepteula`, remove
it from the script and accept the EULA once by running `testlimit64.exe`
manually.

**PowerShell:**

```powershell
.\run-testlimit.ps1 4096          # ~4 GB per burst, 5 s each
.\run-testlimit.ps1 4096 10       # ~4 GB per burst, 10 s each
```

**cmd.exe:**

```cmd
powershell -ExecutionPolicy Bypass -File run-testlimit.ps1 4096
```

## Building

### CI (recommended — download a prebuilt binary)

Every push builds `mempat.exe` with MSVC on a `windows-latest` runner and
uploads it as an artifact:

1. Open the **Actions** tab → the latest **build** run.
2. Download the **mempat-x64** artifact (a zip containing `mempat.exe`).

Pushing a tag like `v1.0` additionally attaches `mempat.exe` to a GitHub
Release.

### Local

MSVC (Developer Command Prompt):

```cmd
cl /O2 /nologo mempat.c
```

MinGW-w64:

```bash
gcc -O2 mempat.c -o mempat.exe
```

Cross-compile from Linux:

```bash
sudo apt-get install -y gcc-mingw-w64-x86-64
x86_64-w64-mingw32-gcc -O2 mempat.c -o mempat.exe
```

## Interpreting results

- `cycle N ... ok` lines and exit code `0`: memory and the pagefile round-trip
  are intact.
- A `MISMATCH` line and exit code `2`: real corruption — note the address,
  expected, and got values (a single flipped bit points at hardware/ECC;
  wholesale wrong values or another process's range point at a paging/
  hypervisor fault). The process stops at the first mismatch and dumps the whole
  failing page in hex. Under `run-mempat.ps1` that dump is also saved to
  `<pid>_corrupted_page.txt`.
- If the VM itself crashes/BSODs or the process is killed during a run, that is
  itself the signal being hunted (e.g. resource-exhaustion instability).
