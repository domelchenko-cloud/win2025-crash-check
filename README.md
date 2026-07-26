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
  expected value. Mismatches print `cycle / page / offset / address /
  expected / got` (capped at 20 lines per cycle; all are counted).
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
mempat.exe [MB] [iters] [offset] [stride] [seed]
```

| Arg      | Meaning                                   | Default        |
|----------|-------------------------------------------|----------------|
| `MB`     | Total area to allocate, in MiB            | `256`          |
| `iters`  | Number of cycles (`0` = run forever)      | `0`            |
| `offset` | Start byte offset of the pattern in a page| `0`            |
| `stride` | Bytes between `uint64` slots within a page| `8` (dense)    |
| `seed`   | Pattern base value (`0x...` accepted)     | `PID << 40`    |

Examples:

```bat
mempat.exe 256                 :: 256 MB, forever, dense, PID-based seed
mempat.exe 7000 100 0 64       :: ~7 GB, 100 cycles, one u64 per 64 B (cache-line spacing)
mempat.exe 512 0 0 8 0xABCD00  :: explicit seed for reproducible / coordinated runs
```

On an 8 GB VM, an area of ~7 GB drives heavy bidirectional paging; stop a
forever-run with `Ctrl+C`.

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

- `errors=0` every cycle: memory and the pagefile round-trip are intact.
- Any `MISMATCH` line: real corruption — note the address, expected, and got
  values (a single flipped bit points at hardware/ECC; wholesale wrong values
  or another process's range point at a paging/hypervisor fault).
- If the VM itself crashes/BSODs or the process is killed during a run, that is
  itself the signal being hunted (e.g. resource-exhaustion instability).
