// ============================================================================
// stset_tb.cpp — standalone Verilator unit testbench for ooo_stset (D021)
//
// Drives the raw predictor ports against a C++ golden model that mirrors
// the RTL register semantics exactly:
//   * SSIT merge rules (fresh-alloc incl. allocator wrap, one-sided share
//     both directions, both-valid -> min(ssid)), and the load/store
//     index-alias case (both PCs hit one SSIT entry)
//   * LFST last-writer-wins (same-cycle slot0+slot1 stores, equal ssid)
//   * the slot1 same-cycle bypass (slot0 store write forwarded to slot1's
//     LFST view) plus its negative cases
//   * training-cycle port hijack (lk_ssv* forced 0, train_busy up)
//   * cyclic decay (built with -GDECAY_W=8 so epochs are 256 cycles),
//     including decay-vs-training same-cycle (training wins)
//   * ~200k random interleavings of {lookup, store-dispatch, train, idle}
//
// Build/run: make stset-tb
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstdlib>

#include "Vooo_stset.h"
#include "verilated.h"

// MinGW has no weak symbols; Verilator's legacy time hook must exist.
double sc_time_stamp() { return 0.0; }

namespace {

Vooo_stset* top;
uint64_t    ticks = 0;
int         failures = 0;

// TB build parameters (must match the make recipe's -G overrides).
// TB_SSIT_AW is set from the make variable STSET_AW so the SSIT=32 LE
// escape (SSIT_AW=5) can be exercised: make stset-tb STSET_AW=5
#ifndef TB_SSIT_AW
#define TB_SSIT_AW 6
#endif
const int      SSIT_D    = 1 << TB_SSIT_AW;
const uint32_t DECAY_MAX = 0xFF;    // DECAY_W = 8 (TB override)

// golden model registers
bool    g_ssit_v[SSIT_D];
uint8_t g_ssit_id[SSIT_D];
bool    g_lfst_v[16];
uint8_t g_lfst_pos[16];
uint8_t g_alloc = 0;
uint32_t g_decay = 0;

void expect(const char* what, uint32_t got, uint32_t want) {
    if (got != want) {
        printf("FAIL %s: got 0x%x want 0x%x (tick %llu)\n",
               what, got, want, (unsigned long long)ticks);
        ++failures;
    }
}

// simple deterministic PRNG (xorshift32) — reproducible across platforms
uint32_t rng_state = 0xD021D021u;
uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

// check every combinational output against the golden pre-edge state,
// then advance both the DUT (posedge) and the golden model one cycle
void step() {
    top->eval();

    // golden view of the (possibly hijacked) SSIT read ports
    int ridx0 = (top->train_en ? top->train_ldpc : top->lk_pc0) & (SSIT_D - 1);
    int ridx1 = (top->train_en ? top->train_stpc : top->lk_pc1) & (SSIT_D - 1);
    bool    rv0  = g_ssit_v[ridx0];
    uint8_t rid0 = g_ssit_id[ridx0];
    bool    rv1  = g_ssit_v[ridx1];
    uint8_t rid1 = g_ssit_id[ridx1];

    expect("lk_ssv0",  top->lk_ssv0,  (rv0 && !top->train_en) ? 1 : 0);
    expect("lk_ssid0", top->lk_ssid0, rid0);
    expect("lk_ssv1",  top->lk_ssv1,  (rv1 && !top->train_en) ? 1 : 0);
    expect("lk_ssid1", top->lk_ssid1, rid1);
    expect("lf_v0",    top->lf_v0,    g_lfst_v[rid0] ? 1 : 0);
    expect("lf_pos0",  top->lf_pos0,  g_lfst_pos[rid0]);
    bool byp1 = top->stw0_en && (top->stw0_ssid == rid1);
    expect("lf_v1",    top->lf_v1,   byp1 ? 1 : (g_lfst_v[rid1] ? 1 : 0));
    expect("lf_pos1",  top->lf_pos1, byp1 ? top->stw0_sqpos : g_lfst_pos[rid1]);
    expect("train_busy", top->train_busy, top->train_en);

    // ---- advance the DUT one posedge -----------------------------------
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    ++ticks;

    // ---- advance the golden model with the same write priorities -------
    uint8_t old_alloc = g_alloc;
    // (1) decay clear at counter wrap
    if (g_decay == DECAY_MAX) {
        for (int i = 0; i < SSIT_D; ++i) g_ssit_v[i] = false;
        for (int i = 0; i < 16; ++i)     g_lfst_v[i] = false;
        g_alloc = 0;
    }
    g_decay = (g_decay + 1) & DECAY_MAX;
    // (2) LFST writes, slot1 (younger) last so it wins ssid collisions
    if (top->stw0_en) {
        g_lfst_v[top->stw0_ssid]   = true;
        g_lfst_pos[top->stw0_ssid] = top->stw0_sqpos;
    }
    if (top->stw1_en) {
        g_lfst_v[top->stw1_ssid]   = true;
        g_lfst_pos[top->stw1_ssid] = top->stw1_sqpos;
    }
    // (3) training merge LAST — wins over a same-cycle decay clear; uses
    // pre-edge rv*/rid* and the pre-decay allocator, exactly like the RTL
    if (top->train_en) {
        int li = top->train_ldpc & (SSIT_D - 1);
        int si = top->train_stpc & (SSIT_D - 1);
        if (!rv0 && !rv1) {
            g_ssit_v[li] = true; g_ssit_id[li] = old_alloc & 0xF;
            g_ssit_v[si] = true; g_ssit_id[si] = old_alloc & 0xF;
            g_alloc = (old_alloc + 1) & 0xF;
        } else if (rv0 && !rv1) {
            g_ssit_v[si] = true; g_ssit_id[si] = rid0;
        } else if (!rv0 && rv1) {
            g_ssit_v[li] = true; g_ssit_id[li] = rid1;
        } else {
            uint8_t m = (rid0 < rid1) ? rid0 : rid1;
            g_ssit_v[li] = true; g_ssit_id[li] = m;
            g_ssit_v[si] = true; g_ssit_id[si] = m;
        }
    }
}

void idle_inputs() {
    top->lk_pc0 = 0; top->lk_pc1 = 0;
    top->stw0_en = 0; top->stw0_ssid = 0; top->stw0_sqpos = 0;
    top->stw1_en = 0; top->stw1_ssid = 0; top->stw1_sqpos = 0;
    top->train_en = 0; top->train_ldpc = 0; top->train_stpc = 0;
}

void train(int ldpc, int stpc) {
    idle_inputs();
    top->train_en = 1; top->train_ldpc = ldpc; top->train_stpc = stpc;
    step();
    idle_inputs();
}

void lookup2(int pc0, int pc1) {
    idle_inputs();
    top->lk_pc0 = pc0; top->lk_pc1 = pc1;
    // step() checks all outputs against golden — callers just sequence
    step();
    idle_inputs();
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vooo_stset;

    for (int i = 0; i < SSIT_D; ++i) { g_ssit_v[i] = false; g_ssit_id[i] = 0; }
    for (int i = 0; i < 16; ++i)     { g_lfst_v[i] = false; g_lfst_pos[i] = 0; }

    // reset
    idle_inputs();
    top->reset = 1;
    top->clk = 0; top->eval(); top->clk = 1; top->eval();
    top->reset = 0;

    // ---- directed phase -------------------------------------------------
    // 1. fresh merge: neither PC in a set -> both get ssid 0
    train(5, 9);
    lookup2(5, 9);           // step() verifies ssv=1 both, same ssid
    // 2. one-sided share: new store PC joins the load's set
    train(5, 20);
    lookup2(20, 5);
    // 3. second independent set (ssid 1), then min-merge across sets
    train(30, 40);           // fresh -> ssid 1
    train(5, 40);            // both valid -> both take min = 0
    lookup2(5, 40);
    // 4. load/store index-alias: both training PCs hit one SSIT entry
    train(12, 12);
    lookup2(12, 12);
    // 5. LFST: write via store dispatch, read back; same-cycle
    //    last-writer-wins; slot1 bypass positive + negative
    idle_inputs();
    top->stw0_en = 1; top->stw0_ssid = 0; top->stw0_sqpos = 3;
    step();                                    // LFST[0] = slot 3
    idle_inputs();
    lookup2(5, 20);                            // lf_v=1 pos=3 via golden
    idle_inputs();                             // both stores, same ssid:
    top->stw0_en = 1; top->stw0_ssid = 2; top->stw0_sqpos = 4;
    top->stw1_en = 1; top->stw1_ssid = 2; top->stw1_sqpos = 5;
    step();                                    // slot1 wins -> pos=5
    idle_inputs();
    top->lk_pc1 = 5;                           // pc 5 has ssid 0
    top->stw0_en = 1; top->stw0_ssid = 0; top->stw0_sqpos = 6;
    step();                                    // bypass: lf_pos1 must be 6
    idle_inputs();
    top->lk_pc1 = 5;
    top->stw0_en = 1; top->stw0_ssid = 7; top->stw0_sqpos = 6;
    step();                                    // ssid mismatch: no bypass
    idle_inputs();

    // 6. decay boundary: run past the 256-cycle wrap, then verify cleared
    for (int i = 0; i < 300; ++i) { idle_inputs(); step(); }
    lookup2(5, 40);                            // golden says ssv=0 now

    // 7. decay-vs-training same cycle: training survives the clear.
    //    Align to the wrap cycle, then train exactly on it.
    while (g_decay != DECAY_MAX) { idle_inputs(); step(); }
    train(33, 44);                             // lands on the clear cycle
    lookup2(33, 44);                           // must be valid (trained)

    if (failures == 0)
        printf("stset-tb: directed phase clean (%llu ticks)\n",
               (unsigned long long)ticks);

    // ---- random phase ----------------------------------------------------
    // ~200k cycles of random interleavings; every output checked every
    // cycle against the golden model. DECAY_W=8 -> ~780 decay epochs.
    for (int n = 0; n < 200000; ++n) {
        idle_inputs();
        top->lk_pc0 = rnd() & 63;
        top->lk_pc1 = rnd() & 63;
        uint32_t r = rnd();
        if ((r & 7) == 0) {                    // 1/8: train
            top->train_en   = 1;
            top->train_ldpc = rnd() & 63;
            top->train_stpc = rnd() & 63;
        }
        if ((r & 0x30) == 0) {                 // 1/4 overall: store dispatch
            top->stw0_en    = 1;
            top->stw0_ssid  = rnd() & 15;
            top->stw0_sqpos = rnd() & 7;
            if (r & 0x40) {                    // sometimes a pair
                top->stw1_en    = 1;
                top->stw1_ssid  = rnd() & 15;
                // two same-cycle stores never share an SQ slot (RTL fatal)
                top->stw1_sqpos = (top->stw0_sqpos + 1 + (rnd() % 7)) & 7;
            }
        }
        step();
    }

    printf("stset-tb: %s (%d failures, %llu ticks)\n",
           failures == 0 ? "PASS" : "FAIL",
           failures, (unsigned long long)ticks);
    delete top;
    return failures ? 1 : 0;
}
