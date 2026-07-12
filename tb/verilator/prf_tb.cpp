// ============================================================================
// prf_tb.cpp — standalone Verilator unit testbench for ooo_prf (D025)
//
// Proves the M9K/LVT-banked, folded-read PRF is bit-identical to the simple
// async register file it replaces. The golden model is exactly that async
// file (`rd_bypass`) plus the one-cycle read-address latency of the fold:
//   * a read presented in cycle C-1 is observed in cycle C;
//   * the observed value is the current-cycle (C) write-first bypass over the
//     three write ports, else regs[tag] as committed through cycle C-1;
//   * p0 always reads 0.
// The golden is deliberately blind to the DUT internals (banks / LVT / the
// direct+shadow OLD_DATA patch): if the DUT honours the async contract the TB
// passes, and any RDW/bypass corner that breaks it fails here — the same
// golden-model style as stset_tb / npu_tb.
//
// Build/run: make prf-tb
// ============================================================================
#include <cstdio>
#include <cstdint>

#include "Vooo_prf.h"
#include "verilated.h"

// MinGW has no weak symbols; Verilator's legacy time hook must exist.
double sc_time_stamp() { return 0.0; }

namespace {

Vooo_prf* top;
uint64_t  ticks = 0;
int       failures = 0;

// golden state
uint32_t g_regs[64];        // committed register values (writes <= cycle C-1)
uint8_t  g_prev_stag[6];    // read tags presented last cycle (observed now)
uint8_t  g_cur_stag[6];     // read tags presented this cycle

// deterministic PRNG (xorshift32), reproducible across platforms
uint32_t rng_state = 0xD025D025u;
uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return rng_state = x;
}

void set_reads(uint8_t t0, uint8_t t1, uint8_t t2,
               uint8_t t3, uint8_t t4, uint8_t t5) {
    g_cur_stag[0] = t0; g_cur_stag[1] = t1; g_cur_stag[2] = t2;
    g_cur_stag[3] = t3; g_cur_stag[4] = t4; g_cur_stag[5] = t5;
    top->s0a_tag = t0; top->s0b_tag = t1;
    top->s1a_tag = t2; top->s1b_tag = t3;
    top->s2a_tag = t4; top->s2b_tag = t5;
}

void idle_writes() {
    top->w0_en = 0; top->w0_tag = 0; top->w0_data = 0;
    top->w1_en = 0; top->w1_tag = 0; top->w1_data = 0;
    top->w2_en = 0; top->w2_tag = 0; top->w2_data = 0;
}

uint32_t read_out(int r) {
    switch (r) {
        case 0:  return top->r0a; case 1: return top->r0b;
        case 2:  return top->r1a; case 3: return top->r1b;
        case 4:  return top->r2a; default: return top->r2b;
    }
}

// async reference (rd_bypass) for a read tag observed THIS cycle
uint32_t golden(uint8_t tag) {
    if (tag == 0)                                return 0;
    if (top->w0_en && top->w0_tag == tag)        return top->w0_data;
    if (top->w1_en && top->w1_tag == tag)        return top->w1_data;
    if (top->w2_en && top->w2_tag == tag)        return top->w2_data;
    return g_regs[tag];
}

// check all six outputs against golden pre-edge state, then advance one cycle
void step() {
    top->eval();
    for (int r = 0; r < 6; ++r) {
        uint32_t got = read_out(r);
        uint32_t exp = golden(g_prev_stag[r]);
        if (got != exp) {
            printf("FAIL port%d tag=%d: got %08x want %08x (tick %llu)\n",
                   r, g_prev_stag[r], got, exp, (unsigned long long)ticks);
            ++failures;
        }
    }
    // posedge
    top->clk = 0; top->eval(); top->clk = 1; top->eval(); ++ticks;
    // advance golden with the same write commits (single-assignment => order
    // among ports is immaterial)
    if (top->w0_en) g_regs[top->w0_tag] = top->w0_data;
    if (top->w1_en) g_regs[top->w1_tag] = top->w1_data;
    if (top->w2_en) g_regs[top->w2_tag] = top->w2_data;
    for (int r = 0; r < 6; ++r) g_prev_stag[r] = g_cur_stag[r];
}

// convenience: one write port active this cycle (tag in [1,63])
void set_w0(uint8_t tag, uint32_t data) {
    top->w0_en = 1; top->w0_tag = tag; top->w0_data = data;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vooo_prf;

    for (int i = 0; i < 64; ++i) g_regs[i] = 0;
    for (int i = 0; i < 6; ++i) { g_prev_stag[i] = 0; g_cur_stag[i] = 0; }

    // reset
    idle_writes();
    set_reads(0, 0, 0, 0, 0, 0);
    top->reset = 1;
    top->clk = 0; top->eval(); top->clk = 1; top->eval();
    top->reset = 0;
    for (int i = 0; i < 6; ++i) { g_prev_stag[i] = 0; g_cur_stag[i] = 0; }

    // ---- directed phase -------------------------------------------------
    // A. bank path (read >= write+2): write p5, then read it two cycles on
    idle_writes(); set_w0(5, 0x0000AAAA); set_reads(0,0,0,0,0,0); step();
    idle_writes();                        set_reads(5,0,0,0,0,0); step(); // present
    idle_writes();                        set_reads(0,0,0,0,0,0); step(); // observe A -> 0xAAAA
    // B. shadow path (read == write+1): present p7 the same cycle it is written
    idle_writes(); set_w0(7, 0x0000BBBB); set_reads(7,0,0,0,0,0); step();
    idle_writes();                        set_reads(0,0,0,0,0,0); step(); // observe -> 0xBBBB
    // C. direct path (read == write): present p9, write p9 the next cycle
    idle_writes();                        set_reads(9,0,0,0,0,0); step();
    idle_writes(); set_w0(9, 0x0000CCCC); set_reads(0,0,0,0,0,0); step(); // observe -> 0xCCCC
    // D. p0 always zero even while p0's "bank" is poked via a stale read
    idle_writes();                        set_reads(0,0,0,0,0,0); step();
    // E. all six ports read the same freshly-written tag (replication check)
    idle_writes(); set_w0(13, 0x12345678); set_reads(0,0,0,0,0,0); step();
    idle_writes();                         set_reads(13,13,13,13,13,13); step();
    idle_writes();                         set_reads(0,0,0,0,0,0); step();
    // F. three simultaneous writes to distinct banks, read all three back
    idle_writes();
    top->w0_en=1; top->w0_tag=20; top->w0_data=0x111;
    top->w1_en=1; top->w1_tag=21; top->w1_data=0x222;
    top->w2_en=1; top->w2_tag=22; top->w2_data=0x333;
    set_reads(0,0,0,0,0,0); step();
    idle_writes(); set_reads(20,21,22,0,0,0); step();
    idle_writes(); set_reads(0,0,0,0,0,0); step();

    if (failures == 0)
        printf("prf-tb: directed phase clean (%llu ticks)\n",
               (unsigned long long)ticks);

    // ---- random phase ----------------------------------------------------
    // ~300k cycles: random reads over [0,63] (incl. p0), up to three
    // simultaneous writes with DISTINCT tags in [1,63] (single-assignment).
    for (int n = 0; n < 300000; ++n) {
        idle_writes();
        set_reads(rnd() & 63, rnd() & 63, rnd() & 63,
                  rnd() & 63, rnd() & 63, rnd() & 63);
        uint32_t r = rnd();
        // pick up to 3 distinct write tags in [1,63]
        uint8_t t0 = 1 + (rnd() % 63);
        uint8_t t1 = 1 + (rnd() % 63);
        uint8_t t2 = 1 + (rnd() % 63);
        bool e0 = (r & 3) != 0;                 // 3/4 of cycles: w0 writes
        bool e1 = (r & 0xC) != 0 && t1 != t0;   // distinct-tag guard
        bool e2 = (r & 0x30) != 0 && t2 != t0 && t2 != t1;
        if (e0) set_w0(t0, rnd());
        if (e1) { top->w1_en=1; top->w1_tag=t1; top->w1_data=rnd(); }
        if (e2) { top->w2_en=1; top->w2_tag=t2; top->w2_data=rnd(); }
        step();
    }

    printf("prf-tb: %s (%d failures, %llu ticks)\n",
           failures == 0 ? "PASS" : "FAIL",
           failures, (unsigned long long)ticks);
    delete top;
    return failures ? 1 : 0;
}
