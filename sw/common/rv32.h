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
#define MMIO_HEXLO       (*(volatile uint32_t *)0x4000000Cu) // {HEX3..HEX0} D023
#define MMIO_SIM_CONSOLE (*(volatile uint32_t *)0x40000010u) // sim putchar
#define MMIO_HEXHI       (*(volatile uint32_t *)0x40000014u) // {HEX5,HEX4}  D023
// SIM_EXIT and SIM_CONSOLE are harness conventions: the Verilator TB snoops
// the store bus for these addresses; mmio.v ignores them (no-op on FPGA).

// 7-segment font, one byte per digit: raw ACTIVE-LOW segments (0 lights),
// bit i = segment i (a..g), bit 7 = decimal point (kept dark). The hardware
// register drives the pins verbatim — this table IS the display encoding.
#define HEX_BLANK 0xFFu
static const uint8_t hex_font[10] = {
    0xC0, 0xF9, 0xA4, 0xB0, 0x99,   // 0 1 2 3 4
    0x92, 0x82, 0xF8, 0x80, 0x90    // 5 6 7 8 9
};

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
