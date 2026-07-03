// ============================================================================
// npu_tb.cpp — standalone Verilator unit testbench for npu_top
//
// Drives the raw MMIO port (no CPU) against a C++ golden tile model:
//   * ID / STATUS semantics, A/B register readback, unmapped reads
//   * thousands of random tiles: CLR, GO|CLR, accumulation chains of
//     random length, signed extremes (+127 / -128)
//   * pass latency bound (busy must clear within 12 cycles)
// The TB never writes while busy — same contract the cores enforce in
// hardware; npu_top's internal assertion backs it up.
//
// Build/run: make npu-tb
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <memory>

#include "Vnpu_top.h"
#include "verilated.h"

// MinGW has no weak symbols; Verilator's legacy time hook must exist.
double sc_time_stamp() { return 0.0; }

namespace {

const uint32_t NPU_ID_ADDR   = 0x50000000u;
const uint32_t NPU_STATUS    = 0x50000004u;
const uint32_t NPU_CTRL      = 0x50000008u;
const uint32_t NPU_A0        = 0x50000010u;
const uint32_t NPU_B0        = 0x50000020u;
const uint32_t NPU_C0        = 0x50000040u;
const uint32_t GO  = 1u;
const uint32_t CLR = 2u;

Vnpu_top* top;
uint64_t  ticks = 0;

void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    ++ticks;
}

void mmio_write(uint32_t addr, uint32_t data) {
    top->we = 1; top->waddr = addr; top->wdata = data;
    tick();
    top->we = 0;
}

uint32_t mmio_read(uint32_t addr) {
    top->raddr = addr;
    top->eval();                       // combinational read port
    return top->rdata;
}

int failures = 0;
void expect(const char* what, uint32_t got, uint32_t want) {
    if (got != want) {
        printf("FAIL %s: got 0x%08x want 0x%08x (tick %llu)\n",
               what, got, want, (unsigned long long)ticks);
        ++failures;
    }
}

// simple deterministic PRNG (xorshift32) — reproducible across platforms
uint32_t rng_state = 0x12345678u;
uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

// golden model state
int8_t  A[4][4], B[4][4];
int32_t C[16];

void golden_go()  { for (int i = 0; i < 4; ++i)
                        for (int j = 0; j < 4; ++j)
                            for (int k = 0; k < 4; ++k)   // wraps like RTL
                                C[i*4+j] = (int32_t)((uint32_t)C[i*4+j]
                                    + (uint32_t)((int32_t)A[i][k]
                                                 * (int32_t)B[k][j])); }
void golden_clr() { for (int i = 0; i < 16; ++i) C[i] = 0; }

void load_tile() {
    for (int i = 0; i < 4; ++i) {
        uint32_t aw = 0, bw = 0;
        for (int k = 0; k < 4; ++k) {
            aw |= (uint32_t)(uint8_t)A[i][k] << (8 * k);
            bw |= (uint32_t)(uint8_t)B[i][k] << (8 * k);   // row i of B
        }
        mmio_write(NPU_A0 + 4u * i, aw);
        mmio_write(NPU_B0 + 4u * i, bw);
    }
}

void randomize_tile() {
    for (int i = 0; i < 4; ++i)
        for (int k = 0; k < 4; ++k) {
            A[i][k] = (int8_t)(rnd() & 0xFF);
            B[i][k] = (int8_t)(rnd() & 0xFF);
        }
}

// issue GO (optionally with CLR), wait for completion. The pass latency
// is part of the spec (docs/NPU.md: exactly 10 run cycles) — an EXACT
// check, not a bound: a lengthened pass is otherwise invisible (feeders
// pad zeros, interlocks just hold longer, lockstep never sees busy).
void run_pass(bool with_clr) {
    mmio_write(NPU_CTRL, GO | (with_clr ? CLR : 0u));
    if (with_clr) golden_clr();
    golden_go();
    int waited = 0;
    while ((mmio_read(NPU_STATUS) & 1u) && waited <= 12) {
        tick();
        ++waited;
    }
    expect("pass latency (busy cycles)", (uint32_t)waited, 10u);
    expect("STATUS.done after pass", (mmio_read(NPU_STATUS) >> 1) & 1u, 1u);
}

void check_c() {
    for (int n = 0; n < 16; ++n)
        expect("C readback", mmio_read(NPU_C0 + 4u * n), (uint32_t)C[n]);
}

} // namespace

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);
    top = new Vnpu_top(ctx.get());

    // reset
    top->we = 0; top->raddr = 0; top->waddr = 0; top->wdata = 0;
    top->reset = 1;
    for (int i = 0; i < 4; ++i) tick();
    top->reset = 0;

    // --- directed: ID, STATUS at reset, unmapped/misaligned reads --------
    expect("NPU_ID", mmio_read(NPU_ID_ADDR), 0x4E505501u);
    expect("STATUS at reset", mmio_read(NPU_STATUS), 0u);
    expect("unmapped 0x50000030", mmio_read(0x50000030u), 0u);
    expect("misaligned 0x50000011", mmio_read(0x50000011u), 0u);
    expect("out-of-block 0x50001040", mmio_read(0x50001040u), 0u);

    // --- directed: readback of EVERY staging register ----------------------
    // (a decode swap among A1..A3/B0..B2 would be invisible to the matmul
    // paths — the feeders read a_r/b_r directly, bypassing the read mux)
    for (int i = 0; i < 4; ++i) {
        mmio_write(NPU_A0 + 4u * i, 0xA0000000u + (uint32_t)i);
        mmio_write(NPU_B0 + 4u * i, 0xB0000000u + (uint32_t)i);
    }
    for (int i = 0; i < 4; ++i) {
        expect("A[i] readback", mmio_read(NPU_A0 + 4u * i),
               0xA0000000u + (uint32_t)i);
        expect("B[i] readback", mmio_read(NPU_B0 + 4u * i),
               0xB0000000u + (uint32_t)i);
    }

    // misaligned STORES fall into the unmapped case and are dropped
    mmio_write(NPU_A0 + 1, 0x55AA55AAu);
    mmio_write(NPU_A0 + 2, 0x55AA55AAu);
    expect("A0 after misaligned stores", mmio_read(NPU_A0), 0xA0000000u);

    // --- directed: identity-ish tile, signed extremes ---------------------
    // A = I*127, B[k][j] = -128 everywhere: C[i][j] = 127 * -128 = -16256
    for (int i = 0; i < 4; ++i)
        for (int k = 0; k < 4; ++k) {
            A[i][k] = (i == k) ? 127 : 0;
            B[i][k] = -128;
        }
    load_tile();
    golden_clr();                       // golden mirrors GO|CLR below
    run_pass(true);
    check_c();

    // all-(-128): each C element = 4 * (-128 * -128) accumulated ON TOP
    for (int i = 0; i < 4; ++i)
        for (int k = 0; k < 4; ++k) A[i][k] = B[i][k] = -128;
    load_tile();
    run_pass(false);                    // accumulate, no clear
    check_c();

    // CLR alone: C = 0, done cleared
    mmio_write(NPU_CTRL, CLR);
    golden_clr();
    expect("STATUS after CLR", mmio_read(NPU_STATUS), 0u);
    check_c();

    // CTRL with neither bit: nothing happens
    mmio_write(NPU_CTRL, 0u);
    expect("STATUS after CTRL=0", mmio_read(NPU_STATUS), 0u);
    check_c();

    // writes to read-only addresses are dropped
    mmio_write(NPU_C0, 0x55555555u);
    mmio_write(NPU_ID_ADDR, 0x55555555u);
    check_c();
    expect("NPU_ID unchanged", mmio_read(NPU_ID_ADDR), 0x4E505501u);

    // --- random: tiles + accumulation chains ------------------------------
    const int TRIALS = 2000;
    for (int t = 0; t < TRIALS; ++t) {
        int chain = 1 + (int)(rnd() % 6);          // 1..6 k-tiles
        for (int c = 0; c < chain; ++c) {
            randomize_tile();
            load_tile();
            run_pass(c == 0);                      // GO|CLR first, GO after
        }
        check_c();
        if (failures) break;                       // stop at first bad trial
    }

    if (failures == 0)
        printf("[npu-tb] PASS: %d random chains + directed cases, "
               "%llu cycles\n", TRIALS, (unsigned long long)ticks);
    else
        printf("[npu-tb] FAIL: %d check(s) failed\n", failures);

    top->final();
    delete top;
    return failures ? 1 : 0;
}
