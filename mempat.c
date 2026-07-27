/*
 * mempat - page-granular memory pattern integrity tester
 *
 * Allocates memory in 4 KiB pages and writes an incrementing 64-bit pattern
 * (one value per page, replicated across configurable in-page slots), then
 * reads the whole area back and reports any mismatch. Each cycle continues
 * from the current pattern value. Intended to surface memory / pagefile
 * corruption under pressure on Windows Server 2025 guests.
 *
 * On the first mismatch it prints the location, then dumps the whole failing
 * page in hex (preceded by the expected pattern, start offset and stride) and
 * exits with code 2.
 *
 * The optional "--zero" flag zero-fills the whole allocated region once, right
 * after allocation, before the pattern cycles begin (touches/commits every
 * page with zeros first).
 *
 * All pattern stores and load-backs go through volatile pointers on purpose:
 * without it the optimizer can store-forward the written value, prove the
 * comparison always holds, and delete the entire read-back check.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PGSZ 4096u

/* Dump the failing page in hex, preceded by the expected pattern and the
 * scan parameters (start offset / stride) so a corrupted page can be inspected
 * byte-by-byte. */
static void dump_page(const BYTE* pg, size_t page_index, uint64_t expected,
                      size_t offset, size_t stride, size_t bad_off, uint64_t got) {
    printf("---- corrupted page dump ----\n");
    printf("page        : %llu\n", (unsigned long long)page_index);
    printf("expected    : 0x%016llX  (uint64 pattern written to every slot of this page)\n",
           (unsigned long long)expected);
    printf("got         : 0x%016llX  at in-page offset %llu\n",
           (unsigned long long)got, (unsigned long long)bad_off);
    printf("start offset: %llu\n", (unsigned long long)offset);
    printf("stride      : %llu\n", (unsigned long long)stride);
    printf("page bytes  : (hex, %u bytes, 16 per line)\n", PGSZ);
    for (size_t r = 0; r < PGSZ; r += 16) {
        printf("%04llx:", (unsigned long long)r);
        for (size_t b = 0; b < 16; b++)
            printf(" %02X", pg[r + b]);
        printf("\n");
    }
    printf("---- end dump ----\n");
    fflush(stdout);
}

int main(int argc, char** argv) {
    /* Separate flags from positional args so "--zero" can appear anywhere. */
    int         zero = 0;
    const char* pos[8];
    int         np = 0;
    for (int a = 1; a < argc; a++) {
        if (strcmp(argv[a], "--zero") == 0) { zero = 1; continue; }
        if (np < 8) pos[np++] = argv[a];
    }

    size_t        mb     = (np > 0) ? (size_t)strtoull(pos[0], NULL, 10) : 256;   /* area, MB       */
    unsigned long iters  = (np > 1) ? strtoul(pos[1], NULL, 10)          : 0;     /* 0 = forever    */
    size_t        offset = (np > 2) ? (size_t)strtoul(pos[2], NULL, 10)  : 0;     /* start off/page */
    size_t        stride = (np > 3) ? (size_t)strtoul(pos[3], NULL, 10)  : 8;     /* bytes per slot */
    uint64_t      seed   = (np > 4) ? strtoull(pos[4], NULL, 0)                   /* pattern base   */
                                    : ((uint64_t)GetCurrentProcessId() << 40);    /* unique/process */

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

    printf("pid=%lu area=%lluMB pages=%llu offset=%llu stride=%llu slots/page=%llu seed=0x%016llX zero=%d\n",
           GetCurrentProcessId(), (unsigned long long)mb, (unsigned long long)npages,
           (unsigned long long)offset, (unsigned long long)stride,
           (unsigned long long)slots, (unsigned long long)seed, zero);
    fflush(stdout);

    if (zero) {
        memset(mem, 0, bytes);   /* fill the whole region with zeros (touches every page) */
        printf("zero-filled %lluMB\n", (unsigned long long)(bytes / (1024u * 1024u)));
        fflush(stdout);
    }

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
                    dump_page(pg, i, v, offset, stride, p, got);
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
