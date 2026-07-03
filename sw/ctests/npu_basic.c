// ============================================================================
// npu_basic.c — directed NPU register-semantics test (docs/NPU.md, D014)
//
// Runs identically on both cores under lockstep — the ISS mirrors the NPU,
// so every load/store here is compared against the golden model. The
// back-to-back store->load sequences are the interesting part: they land
// exactly on the hardware ordering interlocks (OoO: IO-load replay + SQ
// drain backpressure, fixing B010; in-order: EX-stage busy stall).
// Returns 0 -> PASS; distinct fail codes otherwise (never 1).
// ============================================================================
#include "../common/rv32.h"
#include "../common/npu.h"

int main(void) {
    // identification + reset state
    if (NPU_ID != NPU_ID_VALUE) return 2;
    if (NPU_STATUS != 0)        return 3;   // not busy, nothing done yet

    // staging-register write -> immediate read-back (B010 shape)
    NPU_A(0) = 0xDEADBEEFu;
    if (NPU_A(0) != 0xDEADBEEFu) return 4;
    NPU_B(3) = 0x0BADF00Du;
    if (NPU_B(3) != 0x0BADF00Du) return 5;

    // unmapped / misaligned reads return 0
    if (*(volatile uint32_t *)0x50000030u != 0) return 6;
    if (*(volatile uint32_t *)0x50001000u != 0) return 7;

    // identity tile: A = I, B = test pattern  =>  C == B (as int8 values)
    static const int8_t ident[4][4] = {
        {1,0,0,0}, {0,1,0,0}, {0,0,1,0}, {0,0,0,1}
    };
    static const int8_t bpat[4][4] = {
        {1, -2, 3, -4}, {5, -6, 7, -8}, {9, -10, 11, -12}, {13, -14, 15, -16}
    };
    npu_tile(&ident[0][0], 4, &bpat[0][0], 4, NPU_GO | NPU_CLR);
    // read C IMMEDIATELY after GO — the interlock must hold this load
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            if (NPU_C(i * 4 + j) != (int32_t)bpat[i][j]) return 8;
    if (NPU_STATUS != 2) return 9;          // done=1, busy unobservable

    // signed extremes, accumulated on top: all(-128) x all(-128)
    // adds 4 * 16384 = 65536 to every element
    static const int8_t neg[4][4] = {
        {-128,-128,-128,-128}, {-128,-128,-128,-128},
        {-128,-128,-128,-128}, {-128,-128,-128,-128}
    };
    npu_tile(&neg[0][0], 4, &neg[0][0], 4, NPU_GO);
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            if (NPU_C(i * 4 + j) != 65536 + (int32_t)bpat[i][j]) return 10;

    // three-tile accumulation chain of the identity: C = 3*B
    npu_tile(&ident[0][0], 4, &bpat[0][0], 4, NPU_GO | NPU_CLR);
    npu_tile(&ident[0][0], 4, &bpat[0][0], 4, NPU_GO);
    npu_tile(&ident[0][0], 4, &bpat[0][0], 4, NPU_GO);
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            if (NPU_C(i * 4 + j) != 3 * (int32_t)bpat[i][j]) return 11;

    // CLR alone: accumulators and done both clear
    NPU_CTRL = NPU_CLR;
    if (NPU_STATUS != 0) return 12;
    for (int n = 0; n < 16; n++)
        if (NPU_C(n) != 0) return 13;

    // CTRL with neither bit set: a no-op
    NPU_CTRL = 0;
    if (NPU_STATUS != 0) return 14;

    // writes to read-only registers are dropped
    *(volatile uint32_t *)0x50000040u = 0x55555555u;  // C0
    *(volatile uint32_t *)0x50000000u = 0x55555555u;  // ID
    if (NPU_C(0) != 0)              return 15;
    if (NPU_ID  != NPU_ID_VALUE)    return 16;

    // EVERY staging register reads back (a decode swap among A1..A3 /
    // B0..B2 is invisible to the matmul paths — the array feeders bypass
    // the read mux — so it must be pinned here)
    for (int i = 0; i < 4; i++) {
        NPU_A(i) = 0xA0u + (uint32_t)i;
        NPU_B(i) = 0xB0u + (uint32_t)i;
    }
    for (int i = 0; i < 4; i++) {
        if (NPU_A(i) != 0xA0u + (uint32_t)i) return 17;
        if (NPU_B(i) != 0xB0u + (uint32_t)i) return 18;
    }

    // documented store quirks (docs/NPU.md): an aligned SB writes the
    // FULL rs2 word — including bits the C abstract machine says a byte
    // store doesn't have, so rs2 must be pinned with inline asm (gcc is
    // free to materialize (uint8_t)0xAA as -86 = 0xFFFFFFAA, and did).
    // A misaligned store misses the exact decode and is dropped.
    {
        uint32_t v = 0xDEADBEAAu;
        __asm__ volatile ("sb %0, 0(%1)"
                          :: "r"(v), "r"(0x50000010u) : "memory");
        if (NPU_A(0) != 0xDEADBEAAu) return 19;    // full rs2 word landed
        __asm__ volatile ("sb %0, 0(%1)"
                          :: "r"(0xBBu), "r"(0x50000011u) : "memory");
        if (NPU_A(0) != 0xDEADBEAAu) return 20;    // misaligned: dropped
    }

    return 0;
}
