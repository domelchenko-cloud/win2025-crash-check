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
current dir / `PATH`). Run `.\run-mempat.ps1 -h` (or `-?` / `/?`) for usage.

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
manually. Run `.\run-testlimit.ps1 -h` (or `-?` / `/?`) for usage.

**PowerShell:**

```powershell
.\run-testlimit.ps1 4096          # ~4 GB per burst, 5 s each
.\run-testlimit.ps1 4096 10       # ~4 GB per burst, 10 s each
```

**cmd.exe:**

```cmd
powershell -ExecutionPolicy Bypass -File run-testlimit.ps1 4096
```

## Disk read/write CRC stress (`fio-crc.fio` + `run-fio-crc.ps1`)

Where `mempat` hammers RAM/pagefile, this drives **direct** (uncached) random
read/write disk I/O with per-block **CRC32C** verification, to catch storage /
backend corruption. It uses [fio](https://github.com/axboe/fio) — install
`fio.exe` for Windows and keep it on `PATH` (or pass `-Fio`).

`run-fio-crc.ps1` computes **2× the logical CPU count** worth of threads, makes
a fresh test directory with several files per thread, and runs `fio-crc.fio`:
`direct=1` random **writes**, each block carrying a self-describing CRC32C
header, with `verify_backlog` continuously going back to **read** and re-check
the blocks just written. The device therefore sees mixed random read/write
traffic and every read is CRC-verified. On the **first** mismatch fio dumps the
bad block and aborts non-zero.

Each thread owns its own files (one writer per file), so this never trips fio's
"multiple writers may overwrite blocks that belong to other jobs" warning and
never false-fails on a block it hasn't written yet.

The wrapper exits `2` on any CRC mismatch (matching `mempat`) and saves the full
fio output — including the bad-block dump — to `fio_crc_FAIL_<timestamp>.txt` in
the current directory. Exit `0` means every block verified.

| Param           | Meaning                                         | Default          |
|-----------------|-------------------------------------------------|------------------|
| `-SizePerJobMB` | Data per thread, in MiB                         | `512`            |
| `-Files`        | Files per thread                                | `4`              |
| `-Jobs`         | Thread count (`0` = auto, 2× logical CPUs)      | `0`              |
| `-Runtime`      | Seconds for the random phase (`0` = one pass)   | `0`              |
| `-Dir`          | Test directory (created if missing)             | `.\fio-crc-data` |
| `-Fio`          | Path to `fio.exe`                               | `fio.exe`        |

Total on-disk footprint ≈ `Jobs × SizePerJobMB`; keep it under the volume's free
space.

**PowerShell:**

```powershell
.\run-fio-crc.ps1                              # 2x CPUs, 512 MB/thread, one pass
.\run-fio-crc.ps1 -SizePerJobMB 1024 -Files 8  # bigger footprint, more files
.\run-fio-crc.ps1 -Runtime 600                 # loop the random phase for 10 min
.\run-fio-crc.ps1 -Dir D:\fio-test             # test a specific volume
```

**cmd.exe:**

```cmd
powershell -ExecutionPolicy Bypass -File run-fio-crc.ps1 -Runtime 600
```

`Ctrl+C` stops fio and the script. A non-zero exit / `fio_crc_FAIL_*.txt` file is
the corruption signal being hunted. Run `.\run-fio-crc.ps1 -h` (or `-?` / `/?`)
for usage.

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
