// ============================================================================
// rv32.h — minimal bare-metal support header for rv32i_cpu programs
//
// MMIO map (rtl/soc/mmio.v — word access ONLY, see BUGLOG watch list) and
// the Zicntr performance counters (rtl/core/csr_file.v, decision D012).
// ============================================================================
#ifndef RV32_H
#define RV32_H

#include <stdint.h>
#include <stddef.h>

// --- MMIO -------------------------------------------------------------------
#define MMIO_LEDS        (*(volatile uint32_t *)0x40000000u)
#define MMIO_SWITCHES    (*(volatile uint32_t *)0x40000004u)
#define MMIO_SIM_EXIT    (*(volatile uint32_t *)0x40000008u) // 1=PASS, else fail
#define MMIO_SIM_CONSOLE (*(volatile uint32_t *)0x40000010u) // sim putchar
// SIM_EXIT and SIM_CONSOLE are harness conventions: the Verilator TB snoops
// the store bus for these addresses; mmio.v ignores them (no-op on FPGA).

// --- performance counters ----------------------------------------------------
static inline uint32_t rdcycle(void) {
    uint32_t v; __asm__ volatile ("rdcycle %0" : "=r"(v)); return v;
}
static inline uint32_t rdinstret(void) {
    uint32_t v; __asm__ volatile ("rdinstret %0" : "=r"(v)); return v;
}

// 64-bit reads need the hi/lo/hi dance from the unprivileged spec: the low
// half may wrap between the two half-reads, so retry until hi is stable.
static inline uint64_t rdcycle64(void) {
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile ("rdcycleh %0" : "=r"(hi));
        __asm__ volatile ("rdcycle  %0" : "=r"(lo));
        __asm__ volatile ("rdcycleh %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}
static inline uint64_t rdinstret64(void) {
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile ("rdinstreth %0" : "=r"(hi));
        __asm__ volatile ("rdinstret  %0" : "=r"(lo));
        __asm__ volatile ("rdinstreth %0" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

// --- libmin.c ---------------------------------------------------------------
void  *memcpy(void *dst, const void *src, size_t n);
void  *memset(void *dst, int c, size_t n);
void  *memmove(void *dst, const void *src, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
char  *strcpy(char *dst, const char *src);

#endif // RV32_H
