// ============================================================================
// lq_tb.cpp — standalone Verilator unit testbench for ooo_lq (D026)
//
// Public-interface golden model for the full 8-entry LQ lifecycle and the
// combinational violation selector.  The model deliberately knows nothing
// about the DUT's balanced reduction tree.  It reproduces the architectural
// contract directly:
//   * state-changing controls take effect at the edge, so the CAM sees the
//     pre-edge LQ state;
//   * matching uses unsigned 6-bit modular ROB ages;
//   * the minimum-age match wins; the lower-index tie rule is defensive
//     because valid in-flight ROB tags (and therefore ages) are unique;
//   * no match drives {vio_en,vio_tag} = {0,0}.
//
// Directed cases cover wraparound, strict-younger filtering, byte overlap,
// multi-hit oldest selection, index/age disagreement, and pre-edge semantics.
// A deterministic 250k-cycle phase then mixes allocation, execute, retire,
// branch/full flush, and forced-overlap store probes while checking every
// combinational result and both free-space flags.
//
// Build/run: make lq-tb
// ============================================================================
#include <cstdio>
#include <cstdint>

#include "Vooo_lq.h"
#include "verilated.h"

double sc_time_stamp() { return 0.0; }

namespace {

struct Entry {
    bool     valid;
    bool     executed;
    uint8_t  tag;
    uint32_t waddr;
    uint8_t  bmask;
};

Vooo_lq* top;
Entry    model[8];
uint64_t cycles = 0;
uint64_t probes = 0;
uint64_t hits = 0;
int      failures = 0;

uint32_t rng_state = 0xD026D026u;
uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

uint8_t age6(uint8_t tag, uint8_t head) {
    return static_cast<uint8_t>((tag - head) & 63u);
}

void clear_model() {
    for (Entry& e : model) e = {false, false, 0, 0, 0};
}

void idle_controls() {
    top->alloc0_en = 0;
    top->alloc0_tag = 0;
    top->alloc1_en = 0;
    top->alloc1_tag = 0;
    top->exec_en = 0;
    top->exec_tag = 0;
    top->exec_waddr = 0;
    top->exec_bytemask = 0;
    top->st_fill_en = 0;
    top->st_tag = 0;
    top->st_waddr = 0;
    top->st_bytemask = 0;
    top->retire0_en = 0;
    top->retire0_tag = 0;
    top->retire1_en = 0;
    top->retire1_tag = 0;
    top->flush_en = 0;
    top->flush_tag = 0;
    top->flush_all = 0;
}

int live_count() {
    int count = 0;
    for (const Entry& e : model) count += e.valid ? 1 : 0;
    return count;
}

void golden_vio(bool& found, uint8_t& winner) {
    found = false;
    winner = 0;
    uint8_t best_age = 63;
    if (!top->st_fill_en) return;

    const uint8_t head = top->head_tag & 63u;
    const uint8_t store_age = age6(top->st_tag & 63u, head);
    for (int i = 0; i < 8; ++i) {
        const Entry& e = model[i];
        const uint8_t load_age = age6(e.tag, head);
        const bool match = e.valid && e.executed
                        && load_age > store_age
                        && e.waddr == (top->st_waddr & 0x3fffffffu)
                        && ((e.bmask & top->st_bytemask) != 0);
        if (match && (!found || load_age < best_age)) {
            found = true;
            best_age = load_age;
            winner = e.tag;
        }
    }
}

void dump_state() {
    std::printf("  head=%u store=%u/%08x/%x en=%u\n",
                unsigned(top->head_tag), unsigned(top->st_tag),
                unsigned(top->st_waddr), unsigned(top->st_bytemask),
                unsigned(top->st_fill_en));
    for (int i = 0; i < 8; ++i) {
        const Entry& e = model[i];
        std::printf("  lq[%d] v=%u x=%u tag=%u age=%u addr=%08x mask=%x\n",
                    i, e.valid, e.executed, unsigned(e.tag),
                    unsigned(age6(e.tag, top->head_tag & 63u)),
                    unsigned(e.waddr), unsigned(e.bmask));
    }
}

void check_comb(const char* phase) {
    top->eval();
    bool exp_en;
    uint8_t exp_tag;
    golden_vio(exp_en, exp_tag);
    if (top->st_fill_en) {
        ++probes;
        if (exp_en) ++hits;
    }

    const bool bad_vio = (bool(top->vio_en) != exp_en)
                      || (uint8_t(top->vio_tag) != exp_tag);
    const int occ = live_count();
    const bool exp_ge1 = occ < 8;
    const bool exp_ge2 = occ < 7;
    const bool bad_free = (bool(top->free_ge1) != exp_ge1)
                       || (bool(top->free_ge2) != exp_ge2);
    if (bad_vio || bad_free) {
        if (failures < 20) {
            std::printf("FAIL %s cycle=%llu: vio got=%u/%u want=%u/%u; "
                        "free got=%u/%u want=%u/%u\n",
                        phase, static_cast<unsigned long long>(cycles),
                        unsigned(top->vio_en), unsigned(top->vio_tag),
                        exp_en, unsigned(exp_tag),
                        unsigned(top->free_ge1), unsigned(top->free_ge2),
                        exp_ge1, exp_ge2);
            dump_state();
        }
        ++failures;
    }
}

void model_next_edge() {
    Entry before[8];
    Entry next[8];
    for (int i = 0; i < 8; ++i) before[i] = next[i] = model[i];

    int free_idx[2] = {-1, -1};
    int nf = 0;
    for (int i = 0; i < 8 && nf < 2; ++i)
        if (!before[i].valid) free_idx[nf++] = i;

    if (top->exec_en) {
        for (int i = 0; i < 8; ++i) {
            if (before[i].valid && before[i].tag == (top->exec_tag & 63u)) {
                next[i].executed = true;
                next[i].waddr = top->exec_waddr & 0x3fffffffu;
                next[i].bmask = top->exec_bytemask & 15u;
            }
        }
    }

    if (top->retire0_en) {
        for (int i = 0; i < 8; ++i)
            if (before[i].valid && before[i].tag == (top->retire0_tag & 63u))
                next[i].valid = false;
    }
    if (top->retire1_en) {
        for (int i = 0; i < 8; ++i)
            if (before[i].valid && before[i].tag == (top->retire1_tag & 63u))
                next[i].valid = false;
    }

    if (top->alloc0_en && free_idx[0] >= 0) {
        Entry& e = next[free_idx[0]];
        e.valid = true;
        e.executed = false;
        e.tag = top->alloc0_tag & 63u;
    }
    const int alloc1_idx = top->alloc0_en ? free_idx[1] : free_idx[0];
    if (top->alloc1_en && alloc1_idx >= 0) {
        Entry& e = next[alloc1_idx];
        e.valid = true;
        e.executed = false;
        e.tag = top->alloc1_tag & 63u;
    }

    if (top->flush_all) {
        for (Entry& e : next) e.valid = false;
    } else if (top->flush_en) {
        const uint8_t head = top->head_tag & 63u;
        const uint8_t flush_age = age6(top->flush_tag & 63u, head);
        for (int i = 0; i < 8; ++i) {
            if (before[i].valid && age6(before[i].tag, head) > flush_age)
                next[i].valid = false;
        }
        // Same-edge dispatch is wrong-path and is always suppressed.
        if (top->alloc0_en && free_idx[0] >= 0) next[free_idx[0]].valid = false;
        if (top->alloc1_en && alloc1_idx >= 0) next[alloc1_idx].valid = false;
    }

    for (int i = 0; i < 8; ++i) model[i] = next[i];
}

void step(const char* phase = "step") {
    check_comb(phase);
    model_next_edge();
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    ++cycles;
    top->clk = 0;
    top->eval();
}

void reset_dut() {
    clear_model();
    idle_controls();
    top->head_tag = 0;
    top->reset = 1;
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    top->clk = 0;
    top->reset = 0;
    top->eval();
}

void alloc_pair(uint8_t t0, bool two = false, uint8_t t1 = 0) {
    idle_controls();
    top->alloc0_en = 1;
    top->alloc0_tag = t0;
    top->alloc1_en = two;
    top->alloc1_tag = t1;
    step("alloc");
}

void execute(uint8_t tag, uint32_t addr, uint8_t mask) {
    idle_controls();
    top->exec_en = 1;
    top->exec_tag = tag;
    top->exec_waddr = addr;
    top->exec_bytemask = mask;
    step("execute");
}

void probe(uint8_t store_tag, uint32_t addr, uint8_t mask,
           bool want_en, uint8_t want_tag, const char* name) {
    idle_controls();
    top->st_fill_en = 1;
    top->st_tag = store_tag;
    top->st_waddr = addr;
    top->st_bytemask = mask;
    top->eval();
    if (bool(top->vio_en) != want_en || uint8_t(top->vio_tag) != want_tag) {
        if (failures < 20)
            std::printf("FAIL directed %s: got=%u/%u want=%u/%u\n", name,
                        unsigned(top->vio_en), unsigned(top->vio_tag),
                        want_en, unsigned(want_tag));
        ++failures;
    }
    step(name);
}

int choose_live(int avoid = -1) {
    int choices[8];
    int n = 0;
    for (int i = 0; i < 8; ++i)
        if (model[i].valid && i != avoid) choices[n++] = i;
    return n ? choices[rnd() % n] : -1;
}

bool tag_live(uint8_t tag) {
    for (const Entry& e : model)
        if (e.valid && e.tag == tag) return true;
    return false;
}

uint8_t unused_tag(uint8_t avoid = 0xff) {
    for (int tries = 0; tries < 128; ++tries) {
        const uint8_t tag = rnd() & 63u;
        if (tag != avoid && !tag_live(tag)) return tag;
    }
    for (int tag = 0; tag < 64; ++tag)
        if (tag != avoid && !tag_live(tag)) return static_cast<uint8_t>(tag);
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vooo_lq;
    reset_dut();

    // ---- directed phase -------------------------------------------------
    // Head=60 forces tags 63/3/8 to represent increasing ages 3/7/12.
    top->head_tag = 60;
    alloc_pair(3, true, 63);  // physical index order intentionally != age
    alloc_pair(8);
    execute(3, 0x12345, 0x2);
    execute(63, 0x12345, 0x1);
    execute(8, 0x12345, 0xc);

    probe(62, 0x12345, 0xf, true, 63, "wrap-multihit-oldest");
    probe(63, 0x12345, 0xf, true, 3, "strict-younger");
    probe(62, 0x12345, 0x4, true, 8, "byte-mask-select");
    probe(62, 0x12345, 0x0, false, 0, "zero-mask-no-hit");
    probe(62, 0x12346, 0xf, false, 0, "word-mismatch");
    probe(9, 0x12345, 0xf, false, 0, "older-or-equal-only");

    // A store in the same edge that first executes a load sees pre-edge
    // executed=0; the following cycle sees it. This locks the cycle contract.
    alloc_pair(12);
    idle_controls();
    top->exec_en = 1;
    top->exec_tag = 12;
    top->exec_waddr = 0x77;
    top->exec_bytemask = 0xf;
    top->st_fill_en = 1;
    top->st_tag = 10;
    top->st_waddr = 0x77;
    top->st_bytemask = 0xf;
    top->eval();
    if (top->vio_en) {
        std::printf("FAIL directed same-edge-exec used post-edge state\n");
        ++failures;
    }
    step("same-edge-exec-prestate");
    probe(10, 0x77, 0xf, true, 12, "post-exec-visible");

    // Retire/flush also affect only the next cycle's CAM view.
    idle_controls();
    top->retire0_en = 1;
    top->retire0_tag = 63;
    top->st_fill_en = 1;
    top->st_tag = 62;
    top->st_waddr = 0x12345;
    top->st_bytemask = 0xf;
    top->eval();
    if (!top->vio_en || top->vio_tag != 63) {
        std::printf("FAIL directed retire edge did not use pre-edge state\n");
        ++failures;
    }
    step("retire-prestate");
    probe(62, 0x12345, 0xf, true, 3, "retire-visible-next-cycle");

    idle_controls();
    top->flush_all = 1;
    step("directed-flush-all");
    probe(0, 0x12345, 0xf, false, 0, "empty-no-hit-tag-zero");

    // B015 reproducer: seven entries live, slot0 is a non-load, and slot1 is
    // the only dispatched load. It must consume free0 even though alloc1_en
    // names the decode slot. The old free1-only logic silently dropped it.
    top->head_tag = 0;
    alloc_pair(2, true, 3);
    alloc_pair(4, true, 5);
    alloc_pair(6, true, 7);
    alloc_pair(8);
    idle_controls();
    top->alloc1_en = 1;
    top->alloc1_tag = 9;
    step("slot1-only-at-occ7");
    execute(9, 0x55, 0xf);
    probe(1, 0x55, 0xf, true, 9, "slot1-only-tracked");
    idle_controls();
    top->flush_all = 1;
    step("post-b015-flush-all");

    if (failures == 0)
        std::printf("lq-tb: directed phase clean (%llu cycles)\n",
                    static_cast<unsigned long long>(cycles));

    // ---- constrained-random lifecycle + selector phase ------------------
    for (int n = 0; n < 250000; ++n) {
        idle_controls();
        top->head_tag = rnd() & 63u;  // includes every modular-wrap geometry

        const int occ = live_count();
        if (occ < 8 && (rnd() & 3u) != 0) {
            const bool slot1_only = (rnd() & 7u) == 0;
            if (slot1_only) {
                top->alloc1_en = 1;
                top->alloc1_tag = unused_tag();
            } else {
                top->alloc0_en = 1;
                top->alloc0_tag = unused_tag();
                if (occ < 7 && (rnd() & 3u) == 0) {
                    top->alloc1_en = 1;
                    top->alloc1_tag = unused_tag(top->alloc0_tag);
                }
            }
        }

        const int ex = choose_live();
        if (ex >= 0 && (rnd() & 1u)) {
            top->exec_en = 1;
            top->exec_tag = model[ex].tag;
            top->exec_waddr = rnd() & 31u;  // small pool forces CAM collisions
            top->exec_bytemask = 1u + (rnd() % 15u);
        }

        const int r0 = choose_live();
        if (r0 >= 0 && (rnd() & 31u) == 0) {
            top->retire0_en = 1;
            top->retire0_tag = model[r0].tag;
            const int r1 = choose_live(r0);
            if (r1 >= 0 && (rnd() & 3u) == 0) {
                top->retire1_en = 1;
                top->retire1_tag = model[r1].tag;
            }
        }

        if ((rnd() & 1023u) == 0) {
            top->flush_all = 1;
        } else if ((rnd() & 63u) == 0) {
            top->flush_en = 1;
            top->flush_tag = rnd() & 63u;
        }

        // Probe almost every cycle. Half of probes reuse an executed load's
        // address/mask to force one- and multi-match reductions.
        top->st_fill_en = (rnd() & 7u) != 0;
        top->st_tag = rnd() & 63u;
        const int match_seed = choose_live();
        if (match_seed >= 0 && model[match_seed].executed && (rnd() & 1u)) {
            top->st_waddr = model[match_seed].waddr;
            top->st_bytemask = model[match_seed].bmask;
        } else {
            top->st_waddr = rnd() & 31u;
            top->st_bytemask = 1u + (rnd() % 15u);
        }

        step("random");
    }

    check_comb("final");
    std::printf("lq-tb: %s (%d failures, %llu cycles, %llu probes, "
                "%llu hits)\n",
                failures == 0 ? "PASS" : "FAIL", failures,
                static_cast<unsigned long long>(cycles),
                static_cast<unsigned long long>(probes),
                static_cast<unsigned long long>(hits));
    delete top;
    return failures ? 1 : 0;
}
