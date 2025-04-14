#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <signal.h>

#define SIZE_MB 10
#define SIZE_BYTES (SIZE_MB * 1024 * 1024)

volatile sig_atomic_t stop = 0;

void handle_signal(int sig) {
    printf("\nReceived signal %d, cleaning up...\n", sig);
    stop = 1;
}

int main() {
    void *hugepage_mem, *nohugepage_mem, *default_mem;

    // Register signal handlers
    signal(SIGINT, handle_signal);   // Ctrl+C
    signal(SIGTERM, handle_signal);  // kill

    // Mapping 1: Hugepage-advised
    hugepage_mem = mmap(NULL, SIZE_BYTES, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (hugepage_mem == MAP_FAILED) {
        perror("mmap hugepage_mem");
        return 1;
    }

    if (madvise(hugepage_mem, SIZE_BYTES, MADV_HUGEPAGE) != 0) {
        perror("madvise MADV_HUGEPAGE");
        munmap(hugepage_mem, SIZE_BYTES);
        return 1;
    }

    // Mapping 2: NO hugepage advised
    nohugepage_mem = mmap(NULL, SIZE_BYTES, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (nohugepage_mem == MAP_FAILED) {
        perror("mmap nohugepage_mem");
        munmap(hugepage_mem, SIZE_BYTES);
        return 1;
    }

    if (madvise(nohugepage_mem, SIZE_BYTES, MADV_NOHUGEPAGE) != 0) {
        perror("madvise MADV_NOHUGEPAGE");
        munmap(hugepage_mem, SIZE_BYTES);
        munmap(nohugepage_mem, SIZE_BYTES);
        return 1;
    }

    // Mapping 3: No madvise at all
    default_mem = mmap(NULL, SIZE_BYTES, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (default_mem == MAP_FAILED) {
        perror("mmap default_mem");
        munmap(hugepage_mem, SIZE_BYTES);
        munmap(nohugepage_mem, SIZE_BYTES);
        return 1;
    }

    // Touch all three memory regions to ensure allocation
    memset(hugepage_mem, 0xA5, SIZE_BYTES);
    memset(nohugepage_mem, 0x5A, SIZE_BYTES);
    memset(default_mem, 0xFF, SIZE_BYTES);

    printf("Memory allocated and madvise applied.\n");
    printf("Mapping summary:\n");
    printf("  [1] hugepage_mem: MADV_HUGEPAGE applied\n");
    printf("  [2] nohugepage_mem: MADV_NOHUGEPAGE applied\n");
    printf("  [3] default_mem: no madvise\n");
    printf("PID: %d — send SIGINT (Ctrl+C) or SIGTERM to exit.\n", getpid());

    // Wait until a termination signal is caught
    while (!stop) {
        pause();  // Sleep until a signal arrives
    }

    // Cleanup all mappings
    munmap(hugepage_mem, SIZE_BYTES);
    munmap(nohugepage_mem, SIZE_BYTES);
    munmap(default_mem, SIZE_BYTES);

    printf("Memory unmapped, exiting.\n");
    return 0;
}
