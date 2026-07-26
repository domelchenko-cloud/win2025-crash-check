/*
 * mempat - page-granular memory pattern integrity tester
 *
 * Allocates memory in 4 KiB pages and writes an incrementing 64-bit pattern
 * (one value per page, replicated across configurable in-page slots), then
 * reads the whole area back and reports any mismatch. Each cycle continues
 * from the current pattern value. Intended to surface memory / pagefile
 * corruption under pressure on Windows Server 2025 guests.
 *
 * All pattern stores and load-backs go through volatile pointers on purpose:
 * without it the optimizer can store-forward the written value, prove the
 * comparison always holds, and delete the entire read-back check.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define PGSZ 4096u

int main(int argc, char** argv) {
    size_t        mb     = (argc > 1) ? (size_t)strtoull(argv[1], NULL, 10) : 256;   /* area, MB       */
    unsigned long iters  = (argc > 2) ? strtoul(argv[2], NULL, 10)          : 0;     /* 0 = forever    */
    size_t        offset = (argc > 3) ? (size_t)strtoul(argv[3], NULL, 10)  : 0;     /* start off/page */
    size_t        stride = (argc > 4) ? (size_t)strtoul(argv[4], NULL, 10)  : 8;     /* bytes per slot */
    uint64_t      seed   = (argc > 5) ? strtoull(argv[5], NULL, 0)                   /* pattern base   */
                                      : ((uint64_t)GetCurrentProcessId() << 40);     /* unique/process */

    if (stride < 8) stride = 8;                 /* must fit a uint64 */
    if (offset + 8 > PGSZ) offset = 0;

    size_t bytes  = mb * (1024u * 1024u);
    size_t npages = bytes / PGSZ;
    if (!npages) { printf("size too small\n"); return 1; }
    bytes = npages * PGSZ;

    BYTE* mem = (BYTE*)VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!mem) { printf("VirtualAlloc(%llu) failed: %lu\n",
                       (unsigned long long)bytes, GetLastError()); return 1; }

    size_t slots = 0;
    for (size_t p = offset; p + 8 <= PGSZ; p += stride) slots++;

    printf("pid=%lu area=%lluMB pages=%llu offset=%llu stride=%llu slots/page=%llu seed=0x%016llX\n",
           GetCurrentProcessId(), (unsigned long long)mb, (unsigned long long)npages,
           (unsigned long long)offset, (unsigned long long)stride,
           (unsigned long long)slots, (unsigned long long)seed);

    uint64_t base = seed;

    for (unsigned long c = 0; iters == 0 || c < iters; c++) {
        /* WRITE: page i gets value base+i, replicated across its slots (wraps naturally) */
        for (size_t i = 0; i < npages; i++) {
            BYTE* pg = mem + i * PGSZ;
            uint64_t v = base + i;
            for (size_t p = offset; p + 8 <= PGSZ; p += stride)
                *(volatile uint64_t*)(pg + p) = v;   /* volatile: force the store to hit memory */
        }

        /* READ + CHECK: same expected value per page; stop on the first mismatch */
        for (size_t i = 0; i < npages; i++) {
            BYTE* pg = mem + i * PGSZ;
            uint64_t v = base + i;
            for (size_t p = offset; p + 8 <= PGSZ; p += stride) {
                uint64_t got = *(volatile uint64_t*)(pg + p);  /* volatile: force a real load-back */
                if (got != v) {
                    printf("MISMATCH cyc %lu page %llu off %llu addr %p exp 0x%016llX got 0x%016llX\n",
                           c, (unsigned long long)i, (unsigned long long)p, (void*)(pg + p),
                           (unsigned long long)v, (unsigned long long)got);
                    fflush(stdout);
                    return 2;   /* corruption detected: signal via exit code and stop */
                }
            }
        }
        printf("cycle %lu base=0x%016llX ok\n", c, (unsigned long long)base);
        fflush(stdout);

        base += npages;    /* continue from current pattern value */
    }

    printf("done. no corruption detected.\n");
    return 0;
}
