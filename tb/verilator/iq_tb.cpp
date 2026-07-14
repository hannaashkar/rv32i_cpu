// ============================================================================
// iq_tb.cpp — standalone public-interface golden model for ooo_iq (D028)
//
// The model deliberately knows nothing about the RTL's reduction-tree
// topology.  It models the architectural scheduler contract directly:
// 16 resident entries, unsigned modular ROB age, port-class arbitration,
// select-time wakeup, monotonically-decaying store masks, load replay/done,
// dual dispatch, and both recovery paths.  Every valid selected 162-bit uop
// is compared word-for-word.  Directed cases are followed by 300,000 legal,
// deterministic random cycles with mandatory functional coverage bins. D030
// deliberately leaves this legacy behavioral model unchanged: if wake-event
// retiming moves any public grant by a cycle, the comparison fails.
//
// Current D028 increment: OUT_LAT=0 (combinational public grants).  The model's
// edge ordering is intentionally explicit so a later registered-grant arm can
// add a one-cycle expected-output queue without mirroring its implementation.
// ============================================================================
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "Vooo_iq.h"
#include "verilated.h"

double sc_time_stamp() { return 0.0; }

namespace {

constexpr int IQD = 16;
constexpr int UOP_WORDS = 6;       // ceil(162 / 32)
constexpr int RANDOM_CYCLES = 300000;

// ooo_uop.vh field positions.  The test intentionally uses an independent
// packed-word representation rather than reaching into DUT internals.
constexpr int B_ISBR    = 6;
constexpr int B_ISJALR  = 7;
constexpr int B_ISLOAD  = 8;
constexpr int B_ISSTORE = 9;
constexpr int B_ISCSR   = 10;
constexpr int B_PS1     = 115;
constexpr int B_PS2     = 121;
constexpr int B_PD      = 127;
constexpr int B_WR      = 133;
constexpr int B_TAG     = 134;

struct Uop {
    std::array<uint32_t, UOP_WORDS> w{};
};

struct Entry {
    bool valid = false;
    bool issued = false;
    bool r1 = false;
    bool r2 = false;
    uint8_t mask = 0;
    Uop u{};
};

struct Decision {
    std::array<int, 3> idx{{-1, -1, -1}};
};

struct Coverage {
    bool occ[IQD + 1]{};
    bool dispatch_width[3]{};
    bool winner[3][IQD]{};
    bool final_slot = false;
    bool full_with_select = false;
    bool simultaneous_dispatch_select = false;
    bool all_three = false;
    bool port0_ctrl = false;
    bool port0_fallback = false;
    bool port1_second = false;
    bool port1_csr = false;
    bool age_wrap = false;
    bool age_tie = false;
    bool wkl = false;
    bool wk0 = false;
    bool wk1 = false;
    bool wake_both_operands = false;
    bool dispatch_wake = false;
    bool wake_q_apply[3][2]{}; // {port0,port1,load} x {source1,source2}
    bool wake_q_all3_same_edge = false;
    bool wake_q_direct_select = false;
    bool wake_q_persist = false;
    bool branch_flush_survivor_q = false;
    bool branch_flush_active_q_persist = false;
    bool stale_q_blocked_full_flush = false;
    bool stale_q_blocked_branch_flush = false;
    bool stale_q_blocked_reset = false;
    bool mask_bit[8]{};
    bool mask_multi = false;
    bool mask_block = false;
    bool mask_decay = false;
    bool load_issue = false;
    bool load_held = false;
    bool replay = false;
    bool done = false;
    bool replay_done = false;
    bool branch_flush = false;
    bool full_flush = false;
    bool alloc_flush = false;
    bool select_flush = false;
    bool reset_with_select = false;
};

enum class Kind { Alu, Ctrl, Load, Store, Csr };

Vooo_iq* top = nullptr;
std::array<Entry, IQD> model{};
Coverage cov{};
uint64_t cycles = 0;
uint64_t payload_checks = 0;
uint64_t selects[3] = {0, 0, 0};
int failures = 0;

uint8_t env_head = 0;
uint8_t env_sq_unknown = 0;
uint8_t env_sq_unknown_raw = 0;

// Coverage-only one-cycle token monitor. The architectural golden model
// intentionally stays at the D029 contract; this monitor attributes a D030
// source/operand bin only in the following cycle, after the matching target
// is known to have survived the capture edge.
int pending_q_target[3][2] = {{-1, -1}, {-1, -1}, {-1, -1}};

uint32_t rng_state = 0xD0281A5Eu;

uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

uint32_t get_bits(const Uop& u, int lo, int width) {
    uint32_t value = 0;
    for (int bit = 0; bit < width; ++bit) {
        const int pos = lo + bit;
        value |= ((u.w[pos >> 5] >> (pos & 31)) & 1u) << bit;
    }
    return value;
}

void set_bits(Uop& u, int lo, int width, uint32_t value) {
    for (int bit = 0; bit < width; ++bit) {
        const int pos = lo + bit;
        const uint32_t mask = 1u << (pos & 31);
        if ((value >> bit) & 1u) u.w[pos >> 5] |= mask;
        else                     u.w[pos >> 5] &= ~mask;
    }
}

bool bit(const Uop& u, int pos) { return get_bits(u, pos, 1) != 0; }
uint8_t ps1(const Uop& u) { return static_cast<uint8_t>(get_bits(u, B_PS1, 6)); }
uint8_t ps2(const Uop& u) { return static_cast<uint8_t>(get_bits(u, B_PS2, 6)); }
uint8_t pd (const Uop& u) { return static_cast<uint8_t>(get_bits(u, B_PD,  6)); }
uint8_t tag(const Uop& u) { return static_cast<uint8_t>(get_bits(u, B_TAG, 6)); }

bool is_ctrl(const Uop& u) { return bit(u, B_ISBR) || bit(u, B_ISJALR); }
bool is_load(const Uop& u) { return bit(u, B_ISLOAD); }
bool is_store(const Uop& u) { return bit(u, B_ISSTORE); }
bool is_mem(const Uop& u) { return is_load(u) || is_store(u); }
bool is_csr(const Uop& u) { return bit(u, B_ISCSR); }
bool writes(const Uop& u) { return bit(u, B_WR); }
bool is_alu(const Uop& u) { return !is_ctrl(u) && !is_mem(u); }

uint8_t age6(uint8_t t, uint8_t head) {
    return static_cast<uint8_t>((t - head) & 63u);
}

Uop make_uop(Kind kind, uint8_t rob_tag, uint8_t src1, uint8_t src2,
             uint8_t dest, bool wr, uint32_t cookie) {
    Uop u;
    // Make every payload independently recognizable, including fields the IQ
    // does not inspect.  The high word is masked to the real 162-bit width.
    uint32_t x = cookie ^ 0x9e3779b9u;
    for (int i = 0; i < UOP_WORDS; ++i) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        u.w[i] = x ^ (0x10203040u * static_cast<uint32_t>(i + 1));
    }
    u.w[5] &= 0x3u;

    set_bits(u, B_ISBR, 5, 0);       // br/jalr/load/store/csr
    switch (kind) {
        case Kind::Alu:   break;
        case Kind::Ctrl:  set_bits(u, B_ISBR,    1, 1); break;
        case Kind::Load:  set_bits(u, B_ISLOAD,  1, 1); break;
        case Kind::Store: set_bits(u, B_ISSTORE, 1, 1); break;
        case Kind::Csr:   set_bits(u, B_ISCSR,   1, 1); break;
    }
    set_bits(u, B_PS1, 6, src1 & 63u);
    set_bits(u, B_PS2, 6, src2 & 63u);
    set_bits(u, B_PD,  6, dest & 63u);
    set_bits(u, B_WR,  1, wr ? 1u : 0u);
    set_bits(u, B_TAG, 6, rob_tag & 63u);
    return u;
}

template <typename Wide>
void drive_wide(Wide& dst, const Uop& u) {
    for (int i = 0; i < UOP_WORDS; ++i) dst[i] = u.w[i];
}

Uop read_sel(int port) {
    Uop u;
    for (int i = 0; i < UOP_WORDS; ++i) {
        if (port == 0)      u.w[i] = top->sel0_uop[i];
        else if (port == 1) u.w[i] = top->sel1_uop[i];
        else                u.w[i] = top->sel2_uop[i];
    }
    u.w[5] &= 0x3u;
    return u;
}

bool uop_equal(const Uop& a, const Uop& b) {
    for (int i = 0; i < UOP_WORDS; ++i)
        if (a.w[i] != b.w[i]) return false;
    return true;
}

void dump_uop(const char* name, const Uop& u) {
    std::printf("  %s=", name);
    for (int i = UOP_WORDS - 1; i >= 0; --i) std::printf("%08x", u.w[i]);
    std::printf(" tag=%u ps=%u/%u pd=%u wr=%u\n", unsigned(tag(u)),
                unsigned(ps1(u)), unsigned(ps2(u)), unsigned(pd(u)),
                unsigned(writes(u)));
}

void dump_state() {
    std::printf("  head=%u sq=%02x raw=%02x\n", unsigned(env_head),
                unsigned(env_sq_unknown), unsigned(env_sq_unknown_raw));
    for (int i = 0; i < IQD; ++i) {
        const Entry& e = model[i];
        if (!e.valid) continue;
        std::printf("  iq[%2d] tag=%2u age=%2u issued=%u r=%u%u mask=%02x "
                    "kind=%c%c%c%c%c\n",
                    i, unsigned(tag(e.u)), unsigned(age6(tag(e.u), env_head)),
                    unsigned(e.issued), unsigned(e.r1), unsigned(e.r2),
                    unsigned(e.mask), is_ctrl(e.u) ? 'C' : '-',
                    is_load(e.u) ? 'L' : '-', is_store(e.u) ? 'S' : '-',
                    is_csr(e.u) ? 'R' : '-', is_alu(e.u) ? 'A' : '-');
    }
}

void fail(const char* phase, const char* what, uint64_t got, uint64_t want) {
    if (failures < 20) {
        std::printf("FAIL iq-tb cycle=%llu phase=%s %s got=%llu want=%llu\n",
                    static_cast<unsigned long long>(cycles), phase, what,
                    static_cast<unsigned long long>(got),
                    static_cast<unsigned long long>(want));
        dump_state();
    }
    ++failures;
}

int live_count() {
    int n = 0;
    for (const Entry& e : model) n += e.valid ? 1 : 0;
    return n;
}

std::vector<int> free_indices() {
    std::vector<int> result;
    for (int i = 0; i < IQD; ++i)
        if (!model[i].valid) result.push_back(i);
    return result;
}

bool ready(const Entry& e) {
    return e.valid && !e.issued && e.r1 && e.r2;
}

int pick_oldest(const std::array<bool, IQD>& eligible) {
    int winner = -1;
    uint8_t best_age = 63;
    for (int i = 0; i < IQD; ++i) {
        if (!eligible[i]) continue;
        const uint8_t a = age6(tag(model[i].u), env_head);
        if (winner < 0 || a < best_age) {
            winner = i;
            best_age = a;
        }
        // Equal ages intentionally retain the first/lower physical index.
    }
    return winner;
}

Decision golden_decision() {
    std::array<bool, IQD> ctrl{};
    std::array<bool, IQD> alu_noncsr{};
    std::array<bool, IQD> alu{};
    std::array<bool, IQD> mem{};
    for (int i = 0; i < IQD; ++i) {
        const Entry& e = model[i];
        const bool rdy = ready(e);
        ctrl[i]       = rdy && is_ctrl(e.u);
        alu[i]        = rdy && is_alu(e.u);
        alu_noncsr[i] = alu[i] && !is_csr(e.u);
        mem[i]        = rdy && is_mem(e.u) && e.mask == 0;
    }

    Decision d;
    d.idx[0] = pick_oldest(ctrl);
    if (d.idx[0] < 0) d.idx[0] = pick_oldest(alu_noncsr);

    if (d.idx[0] >= 0 && alu[d.idx[0]]) alu[d.idx[0]] = false;
    d.idx[1] = pick_oldest(alu);
    d.idx[2] = pick_oldest(mem);
    return d;
}

bool port_valid(int port) {
    return port == 0 ? top->sel0_v : port == 1 ? top->sel1_v : top->sel2_v;
}

void record_decision(const Decision& d) {
    cov.occ[live_count()] = true;
    const int nsel = (d.idx[0] >= 0) + (d.idx[1] >= 0) + (d.idx[2] >= 0);
    if (nsel == 3) cov.all_three = true;
    if (live_count() == IQD && nsel != 0) cov.full_with_select = true;

    for (int p = 0; p < 3; ++p) {
        if (d.idx[p] < 0) continue;
        cov.winner[p][d.idx[p]] = true;
        ++selects[p];
    }
    if (d.idx[0] >= 0) {
        if (is_ctrl(model[d.idx[0]].u)) cov.port0_ctrl = true;
        else                            cov.port0_fallback = true;
    }
    if (d.idx[1] >= 0 && is_csr(model[d.idx[1]].u)) cov.port1_csr = true;

    std::array<bool, IQD> all_alu{};
    for (int i = 0; i < IQD; ++i) all_alu[i] = ready(model[i]) && is_alu(model[i].u);
    const int first_alu = pick_oldest(all_alu);
    if (d.idx[0] >= 0 && d.idx[0] == first_alu && d.idx[1] >= 0)
        cov.port1_second = true;

    for (int i = 0; i < IQD; ++i) {
        if (!model[i].valid) continue;
        if (env_head >= 48 && tag(model[i].u) < 16) cov.age_wrap = true;
        if (ready(model[i]) && is_mem(model[i].u) && model[i].mask != 0)
            cov.mask_block = true;
        for (int j = i + 1; j < IQD; ++j) {
            if (model[j].valid && ready(model[i]) && ready(model[j])
                && age6(tag(model[i].u), env_head)
                   == age6(tag(model[j].u), env_head))
                cov.age_tie = true;
        }
    }
}

void check_comb(const char* phase, const Decision& d) {
    top->eval();
    const int free = IQD - live_count();
    if (static_cast<bool>(top->free_ge1) != (free >= 1))
        fail(phase, "free_ge1", top->free_ge1, free >= 1);
    if (static_cast<bool>(top->free_ge2) != (free >= 2))
        fail(phase, "free_ge2", top->free_ge2, free >= 2);

    for (int p = 0; p < 3; ++p) {
        const bool want_v = d.idx[p] >= 0;
        if (port_valid(p) != want_v) {
            char what[32]; std::snprintf(what, sizeof(what), "sel%d_v", p);
            fail(phase, what, port_valid(p), want_v);
            continue;
        }
        if (!want_v) continue;
        const Uop got = read_sel(p);
        const Uop& want = model[d.idx[p]].u;
        ++payload_checks;
        if (!uop_equal(got, want)) {
            if (failures < 20) {
                std::printf("FAIL iq-tb cycle=%llu phase=%s sel%d payload\n",
                            static_cast<unsigned long long>(cycles), phase, p);
                dump_uop("got ", got);
                dump_uop("want", want);
                dump_state();
            }
            ++failures;
        }
    }
    record_decision(d);
}

bool wake_from_port(const Decision& d, int port, uint8_t source) {
    if (port > 1 || d.idx[port] < 0) return false;
    const Uop& u = model[d.idx[port]].u;
    return writes(u) && pd(u) == source;
}

bool wakes(const Decision& d, uint8_t source) {
    return wake_from_port(d, 0, source)
        || wake_from_port(d, 1, source)
        || (top->wkl_en && ((top->wkl_tag & 63u) == source));
}

void install_dispatch(Entry& dst, const Uop& u, bool in_r1, bool in_r2,
                      uint8_t in_mask, const Decision& d) {
    dst.valid = true;
    dst.issued = false;
    dst.u = u;
    dst.r1 = in_r1 || wakes(d, ps1(u));
    dst.r2 = in_r2 || wakes(d, ps2(u));
    dst.mask = in_mask;
}

Uop read_disp(int slot) {
    Uop u;
    for (int i = 0; i < UOP_WORDS; ++i)
        u.w[i] = slot == 0 ? top->disp0_uop[i] : top->disp1_uop[i];
    u.w[5] &= 0x3u;
    return u;
}

void model_next_edge(const Decision& d) {
    const std::array<Entry, IQD> before = model;
    std::array<Entry, IQD> next = before;
    const std::vector<int> free = free_indices();
    uint16_t capture_match[3][2]{};

    for (int s = 0; s < 3; ++s)
        for (int op = 0; op < 2; ++op) {
            const int idx = pending_q_target[s][op];
            if (idx >= 0 && before[idx].valid)
                cov.wake_q_apply[s][op] = true;
            pending_q_target[s][op] = -1;
        }

    const bool wk0v = d.idx[0] >= 0 && writes(before[d.idx[0]].u);
    const bool wk1v = d.idx[1] >= 0 && writes(before[d.idx[1]].u);
    if (wk0v && wk1v && top->wkl_en)
        cov.wake_q_all3_same_edge = true;

    // Resident wakeup and wait-mask decay use pre-edge state.
    for (int i = 0; i < IQD; ++i) {
        if (!before[i].valid) continue;
        const bool w1p0 = !before[i].r1 && wake_from_port(d, 0, ps1(before[i].u));
        const bool w1p1 = !before[i].r1 && wake_from_port(d, 1, ps1(before[i].u));
        const bool w2p0 = !before[i].r2 && wake_from_port(d, 0, ps2(before[i].u));
        const bool w2p1 = !before[i].r2 && wake_from_port(d, 1, ps2(before[i].u));
        const bool w1pl = !before[i].r1 && top->wkl_en
                          && ps1(before[i].u) == (top->wkl_tag & 63u);
        const bool w2pl = !before[i].r2 && top->wkl_en
                          && ps2(before[i].u) == (top->wkl_tag & 63u);
        if (w1p0 || w2p0) cov.wk0 = true;
        if (w1p1 || w2p1) cov.wk1 = true;
        if ((w1p0 || w1p1) && (w2p0 || w2p1)) cov.wake_both_operands = true;
        if (w1pl || w2pl) cov.wkl = true;
        if (w1p0) capture_match[0][0] |= static_cast<uint16_t>(1u << i);
        if (w2p0) capture_match[0][1] |= static_cast<uint16_t>(1u << i);
        if (w1p1) capture_match[1][0] |= static_cast<uint16_t>(1u << i);
        if (w2p1) capture_match[1][1] |= static_cast<uint16_t>(1u << i);
        if (w1pl) capture_match[2][0] |= static_cast<uint16_t>(1u << i);
        if (w2pl) capture_match[2][1] |= static_cast<uint16_t>(1u << i);

        if (wakes(d, ps1(before[i].u))) next[i].r1 = true;
        if (wakes(d, ps2(before[i].u))) next[i].r2 = true;
        const uint8_t decayed = before[i].mask & (top->sq_unknown & 0xffu);
        if (decayed != before[i].mask) cov.mask_decay = true;
        next[i].mask = decayed;
    }

    // Current OUT_LAT=0 decisions reserve/deallocate at this edge.
    if (d.idx[0] >= 0) next[d.idx[0]].valid = false;
    if (d.idx[1] >= 0) next[d.idx[1]].valid = false;
    if (d.idx[2] >= 0) {
        if (is_load(before[d.idx[2]].u)) {
            next[d.idx[2]].issued = true;
            cov.load_issue = true;
        } else {
            next[d.idx[2]].valid = false;
        }
    }

    // Replay/done inspect the pre-edge issued-load state.  Done is later and
    // therefore wins over replay for v; replay still clears issued.
    for (int i = 0; i < IQD; ++i) {
        if (!before[i].valid || !is_load(before[i].u) || !before[i].issued)
            continue;
        const bool rep = top->rep_en && tag(before[i].u) == (top->rep_tag & 63u);
        const bool done = top->ldone_en && tag(before[i].u) == (top->ldone_tag & 63u);
        if (rep)  { next[i].issued = false; cov.replay = true; }
        if (done) { next[i].valid = false;  cov.done = true; }
        if (rep && done) cov.replay_done = true;
    }

    const bool a0 = top->disp0_en && !free.empty();
    const bool a1 = top->disp1_en && free.size() >= 2;
    cov.dispatch_width[(a0 ? 1 : 0) + (a1 ? 1 : 0)] = true;
    if (a0 && free.size() == 1) cov.final_slot = true;
    if ((a0 || a1) && (d.idx[0] >= 0 || d.idx[1] >= 0 || d.idx[2] >= 0))
        cov.simultaneous_dispatch_select = true;

    if (a0) {
        const Uop u = read_disp(0);
        const bool dw = (!top->disp0_r1 && wakes(d, ps1(u)))
                     || (!top->disp0_r2 && wakes(d, ps2(u)));
        if (dw) cov.dispatch_wake = true;
        install_dispatch(next[free[0]], u, top->disp0_r1, top->disp0_r2,
                         top->disp0_mask, d);
        for (int b = 0; b < 8; ++b)
            if (top->disp0_mask & (1u << b)) cov.mask_bit[b] = true;
        if ((top->disp0_mask & (top->disp0_mask - 1u)) != 0) cov.mask_multi = true;
    }
    if (a1) {
        const Uop u = read_disp(1);
        const bool dw = (!top->disp1_r1 && wakes(d, ps1(u)))
                     || (!top->disp1_r2 && wakes(d, ps2(u)));
        if (dw) cov.dispatch_wake = true;
        install_dispatch(next[free[1]], u, top->disp1_r1, top->disp1_r2,
                         top->disp1_mask, d);
        for (int b = 0; b < 8; ++b)
            if (top->disp1_mask & (1u << b)) cov.mask_bit[b] = true;
        if ((top->disp1_mask & (top->disp1_mask - 1u)) != 0) cov.mask_multi = true;
    }

    // Recovery is last, matching the RTL's nonblocking-assignment priority.
    if (top->flush_all) {
        cov.full_flush = true;
        if (a0 || a1) cov.alloc_flush = true;
        if (d.idx[0] >= 0 || d.idx[1] >= 0 || d.idx[2] >= 0) cov.select_flush = true;
        for (Entry& e : next) e.valid = false;
    } else if (top->flush_en) {
        cov.branch_flush = true;
        if (a0 || a1) cov.alloc_flush = true;
        if (d.idx[0] >= 0 || d.idx[1] >= 0 || d.idx[2] >= 0) cov.select_flush = true;
        const uint8_t flush_age = age6(top->flush_tag & 63u, env_head);
        for (int i = 0; i < IQD; ++i)
            if (before[i].valid && age6(tag(before[i].u), env_head) > flush_age)
                next[i].valid = false;
        if (a0) next[free[0]].valid = false;
        if (a1) next[free[1]].valid = false;
    }

    // An issued load must remain resident and unavailable until replay/done.
    for (int i = 0; i < IQD; ++i) {
        if (!before[i].valid || !before[i].issued || !is_load(before[i].u)) continue;
        if (d.idx[0] != i && d.idx[1] != i && d.idx[2] != i) cov.load_held = true;
        else fail("model", "issued load selected twice", i, UINT64_MAX);
    }

    // Arm next-cycle coverage only for an entry that remains resident after
    // select/replay/dispatch/recovery priority has been applied.
    for (int s = 0; s < 3; ++s)
        for (int op = 0; op < 2; ++op)
            for (int i = 0; i < IQD; ++i)
                if (pending_q_target[s][op] < 0 && next[i].valid
                    && (capture_match[s][op] & (1u << i)))
                    pending_q_target[s][op] = i;
    model = next;
}

void sync_environment() {
    top->head_tag = env_head;
    top->sq_unknown = env_sq_unknown;
    top->sq_unknown_raw = env_sq_unknown_raw;
}

void zero_wide_inputs() {
    const Uop z{};
    drive_wide(top->disp0_uop, z);
    drive_wide(top->disp1_uop, z);
}

void idle_controls() {
    top->disp0_en = 0; top->disp0_r1 = 0; top->disp0_r2 = 0; top->disp0_mask = 0;
    top->disp1_en = 0; top->disp1_r1 = 0; top->disp1_r2 = 0; top->disp1_mask = 0;
    top->wkl_en = 0; top->wkl_tag = 0;
    top->rep_en = 0; top->rep_tag = 0;
    top->ldone_en = 0; top->ldone_tag = 0;
    top->flush_en = 0; top->flush_tag = 0; top->flush_all = 0;
    zero_wide_inputs();
    sync_environment();
}

void set_dispatch(int slot, const Uop& u, bool r1, bool r2, uint8_t mask) {
    if (slot == 0) {
        top->disp0_en = 1; top->disp0_r1 = r1; top->disp0_r2 = r2;
        top->disp0_mask = mask; drive_wide(top->disp0_uop, u);
    } else {
        top->disp1_en = 1; top->disp1_r1 = r1; top->disp1_r2 = r2;
        top->disp1_mask = mask; drive_wide(top->disp1_uop, u);
    }
}

void step(const char* phase = "step") {
    sync_environment();
    top->clk = 0;
    top->eval();
    const Decision d = golden_decision();
    check_comb(phase, d);

    // Keep the existing RTL invariant's raw-unknown contract honest: raw is
    // allowed to lag a same-cycle fill bypass, but may not omit a resident bit.
    for (const Entry& e : model)
        if (e.valid && (e.mask & ~static_cast<uint8_t>(top->sq_unknown_raw)))
            fail(phase, "stimulus mask not subset raw SQ unknown", e.mask,
                 top->sq_unknown_raw);

    model_next_edge(d);
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    ++cycles;
}

void reset_dut(uint8_t head = 0, uint8_t sq = 0) {
    env_head = head;
    env_sq_unknown = sq;
    env_sq_unknown_raw = sq;
    idle_controls();

    top->reset = 1;
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    for (Entry& e : model) e = Entry{};
    for (int s = 0; s < 3; ++s)
        for (int op = 0; op < 2; ++op)
            pending_q_target[s][op] = -1;
    top->reset = 0;
    top->eval();
}

void dispatch_one(const Uop& u, bool r1, bool r2, uint8_t mask,
                  const char* phase) {
    idle_controls();
    set_dispatch(0, u, r1, r2, mask);
    step(phase);
}

void dispatch_pair(const Uop& u0, bool r10, bool r20, uint8_t m0,
                   const Uop& u1, bool r11, bool r21, uint8_t m1,
                   const char* phase) {
    idle_controls();
    set_dispatch(0, u0, r10, r20, m0);
    set_dispatch(1, u1, r11, r21, m1);
    step(phase);
}

void idle_step(const char* phase) {
    idle_controls();
    step(phase);
}

void directed_phase() {
    uint32_t cookie = 1;

    // Occupancy 0..16, final-slot allocation, full flags, and selection from
    // a full queue.  Every entry waits on the same external load broadcast.
    reset_dut(0);
    for (int i = 0; i < IQD; ++i) {
        dispatch_one(make_uop(Kind::Alu, i, 42, 1, 32 + i, true, cookie++),
                     false, true, 0, "directed-fill-occupancy");
    }
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 42;
    step("directed-full-wakeup");
    idle_step("directed-full-select");

    // Explicit dual dispatch.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 0, 7, 8, 32, true, cookie++), false, false, 0,
                  make_uop(Kind::Load, 1, 9, 10, 33, true, cookie++), false, false, 0,
                  "directed-dual-dispatch");

    // Force every physical leaf to win on every port.  Earlier entries remain
    // unready, so the target's allocation index is deterministic.
    for (int port = 0; port < 3; ++port) {
        for (int target = 0; target < IQD; ++target) {
            reset_dut(0);
            for (int i = 0; i <= target; ++i) {
                const bool chosen = i == target;
                Kind kind = Kind::Alu;
                if (chosen && port == 0) kind = Kind::Ctrl;
                if (chosen && port == 1) kind = Kind::Csr;
                if (chosen && port == 2) kind = Kind::Load;
                const bool wr = kind != Kind::Store;
                dispatch_one(make_uop(kind, i, 45, 46, 32 + (i & 31), wr, cookie++),
                             chosen, true, 0, "directed-winner-fill");
            }
            idle_step("directed-winner-select");
        }
    }

    // Wraparound age ordering plus all three ports in one cycle.  Four entries
    // wait on one broadcast; port0 must prefer control, port1 the oldest ALU,
    // and port2 the oldest memory op.
    reset_dut(60);
    dispatch_pair(make_uop(Kind::Ctrl, 61, 42, 1, 40, true, cookie++), false, true, 0,
                  make_uop(Kind::Alu, 62, 42, 1, 41, true, cookie++), false, true, 0,
                  "directed-wrap-pair0");
    dispatch_pair(make_uop(Kind::Load, 63, 42, 1, 42, true, cookie++), false, true, 0,
                  make_uop(Kind::Alu, 0, 42, 1, 43, true, cookie++), false, true, 0,
                  "directed-wrap-pair1");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 42;
    step("directed-wrap-wakeup");
    idle_step("directed-all-three");

    // Port1 second-oldest exclusion and CSR routing.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Alu, 2, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-port1-second-dispatch");
    idle_step("directed-port1-second-select");

    reset_dut(0);
    dispatch_pair(make_uop(Kind::Csr, 1, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Alu, 2, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-csr-dispatch");
    idle_step("directed-csr-select");

    // Defensive equal-age tie: lower physical index must win first.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 5, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Alu, 5, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-age-tie-dispatch");
    idle_step("directed-age-tie-select");

    // Two internal select broadcasts wake both operands of a resident load.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 50, 1, 40, true, cookie++), false, true, 0,
                  make_uop(Kind::Csr, 2, 50, 1, 41, true, cookie++), false, true, 0,
                  "directed-two-producers");
    dispatch_one(make_uop(Kind::Load, 3, 40, 41, 42, true, cookie++),
                 false, false, 0, "directed-dependent-load");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 50;
    step("directed-producer-ready");
    idle_step("directed-producer-select");
    idle_step("directed-dependent-select");

    // A uop dispatched on the producer's select cycle captures that wakeup.
    reset_dut(0);
    dispatch_one(make_uop(Kind::Alu, 1, 51, 1, 45, true, cookie++),
                 false, true, 0, "directed-dispatch-wake-producer");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 51;
    step("directed-dispatch-wake-arm");
    idle_controls();
    set_dispatch(0, make_uop(Kind::Alu, 2, 45, 1, 46, true, cookie++),
                 false, true, 0);
    step("directed-dispatch-on-select");
    idle_step("directed-dispatched-dependent-select");

    // D030: capture both internal grants and the successful-load wake in one
    // edge, then consume every source/operand combination in the immediately
    // following cycle. The unchanged D029 model proves there is no cycle slip.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 55, 1, 40, true, cookie++), false, true, 0,
                  make_uop(Kind::Csr, 2, 55, 1, 41, true, cookie++), false, true, 0,
                  "directed-d030-all3-producers");
    dispatch_one(make_uop(Kind::Load, 3, 40, 42, 43, true, cookie++),
                 false, false, 0, "directed-d030-all3-load");
    dispatch_pair(make_uop(Kind::Alu, 4, 41, 40, 44, true, cookie++), false, false, 0,
                  make_uop(Kind::Ctrl, 5, 42, 41, 45, true, cookie++), false, false, 0,
                  "directed-d030-all3-dependants");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 55;
    step("directed-d030-all3-arm-producers");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 42;
    step("directed-d030-all3-capture");
    {
        const int before_failures = failures;
        idle_step("directed-d030-all3-direct-select");
        if (failures == before_failures) cov.wake_q_direct_select = true;
    }

    // D030 persistence: q44 resolves only source1 while source2 is blocked.
    // The q token then expires; a later q45 must still release the dependant,
    // proving the source1 match was persisted into sticky resident state.
    reset_dut(0);
    dispatch_one(make_uop(Kind::Alu, 1, 54, 1, 44, true, cookie++),
                 false, true, 0, "directed-d030-persist-producer");
    dispatch_one(make_uop(Kind::Alu, 2, 44, 45, 46, true, cookie++),
                 false, false, 0, "directed-d030-persist-dependant");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 54;
    step("directed-d030-persist-arm");
    idle_step("directed-d030-persist-capture-q44");
    idle_step("directed-d030-persist-q44-expires");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 45;
    step("directed-d030-persist-capture-q45");
    {
        const int before_failures = failures;
        idle_step("directed-d030-persist-select");
        if (failures == before_failures) cov.wake_q_persist = true;
    }

    // Every SQ wait bit, multi-bit masks, and the raw-vs-bypassed clear edge.
    for (int b = 0; b < 8; ++b) {
        const uint8_t m = static_cast<uint8_t>(1u << b);
        reset_dut(0, m);
        dispatch_one(make_uop(Kind::Load, 1, 1, 2, 40, true, cookie++),
                     true, true, m, "directed-mask-dispatch");
        idle_step("directed-mask-block");
        env_sq_unknown = 0;             // same-cycle address-known bypass
        env_sq_unknown_raw = m;         // raw array catches up after the edge
        idle_step("directed-mask-decay");
        env_sq_unknown_raw = 0;
        idle_step("directed-mask-release");
    }
    reset_dut(0, 0xa5);
    dispatch_one(make_uop(Kind::Store, 1, 1, 2, 0, false, cookie++),
                 true, true, 0xa5, "directed-multimask-store");
    idle_step("directed-multimask-block");
    env_sq_unknown = 0; env_sq_unknown_raw = 0xa5;
    idle_step("directed-multimask-decay");
    env_sq_unknown_raw = 0;
    idle_step("directed-multimask-release");

    // Load issue holds its slot, replay re-arms it, and done wins over a
    // same-cycle replay request.
    reset_dut(0);
    const Uop replay_load = make_uop(Kind::Load, 4, 1, 2, 40, true, cookie++);
    dispatch_one(replay_load, true, true, 0, "directed-load-dispatch");
    idle_step("directed-load-first-issue");
    idle_step("directed-load-held");
    idle_controls(); top->rep_en = 1; top->rep_tag = 4;
    step("directed-load-replay");
    idle_step("directed-load-reissue");
    idle_controls();
    top->rep_en = 1; top->rep_tag = 4;
    top->ldone_en = 1; top->ldone_tag = 4;
    step("directed-load-replay-done");
    idle_step("directed-load-free");

    // Branch recovery keeps older/equal entries, kills younger across wrap,
    // and suppresses same-edge dispatch.  Current OUT_LAT=0 selects remain
    // visible in the flush cycle; the CPU's kill_s gates their RF capture.
    reset_dut(60);
    dispatch_one(make_uop(Kind::Alu, 61, 50, 1, 40, true, cookie++),
                 false, true, 0, "directed-flush-older");
    dispatch_one(make_uop(Kind::Alu, 63, 50, 1, 41, true, cookie++),
                 false, true, 0, "directed-flush-equal");
    dispatch_one(make_uop(Kind::Alu, 1, 50, 1, 42, true, cookie++),
                 false, true, 0, "directed-flush-younger");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 50;
    top->flush_en = 1; top->flush_tag = 63;
    step("directed-branch-flush");
    idle_step("directed-branch-survivors");

    reset_dut(0);
    idle_controls();
    set_dispatch(0, make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++),
                 true, true, 0);
    top->flush_en = 1; top->flush_tag = 0;
    step("directed-alloc-branch-flush");
    idle_step("directed-alloc-branch-flush-empty");

    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Alu, 2, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-select-flush-fill");
    idle_controls(); top->flush_en = 1; top->flush_tag = 1;
    step("directed-select-branch-flush");
    idle_step("directed-select-branch-flush-empty");

    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Load, 2, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-full-flush-fill");
    idle_controls();
    set_dispatch(0, make_uop(Kind::Store, 3, 1, 2, 0, false, cookie++),
                 true, true, 0);
    top->flush_all = 1;
    step("directed-select-alloc-full-flush");
    idle_step("directed-full-flush-empty");

    // D030 full-flush stale-tag defence. Capture both internal destination
    // tags plus wkl while the queue is emptied. Consumers dispatched during
    // the following q-active cycle must not store those old matches.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++), true, true, 0,
                  make_uop(Kind::Csr, 2, 1, 2, 41, true, cookie++), true, true, 0,
                  "directed-d030-full-stale-producers");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 42;
    top->flush_all = 1;
    step("directed-d030-full-stale-capture-flush");
    idle_controls();
    set_dispatch(0, make_uop(Kind::Alu, 3, 40, 42, 43, true, cookie++),
                 false, false, 0);
    set_dispatch(1, make_uop(Kind::Csr, 4, 41, 1, 44, true, cookie++),
                 false, true, 0);
    step("directed-d030-full-stale-reuse-dispatch");
    {
        const int before_failures = failures;
        idle_step("directed-d030-full-stale-must-block");
        int waiters = 0;
        for (const Entry& e : model)
            if (e.valid && !e.issued && (!e.r1 || !e.r2)) ++waiters;
        const bool blocked_and_resident = live_count() == 2 && waiters == 2;

        // Positive retention tail: genuine later wakes must recover the exact
        // two consumers. This prevents a false pass if stale-q handling
        // accidentally dropped the dispatches instead of leaving them blocked.
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 41;
        step("directed-d030-full-stale-real-wake-c1");
        idle_step("directed-d030-full-stale-select-c1");
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 40;
        step("directed-d030-full-stale-real-wake-c0-r1");
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 42;
        step("directed-d030-full-stale-real-wake-c0-r2");
        idle_step("directed-d030-full-stale-select-c0");
        if (failures == before_failures && blocked_and_resident
            && live_count() == 0)
            cov.stale_q_blocked_full_flush = true;
    }

    // D030 branch recovery in one sequence: the old producer and dependant
    // survive, the young producer dies, and both internal tags are captured
    // on the flush edge. The survivor must consume pd46 immediately; a newly
    // dispatched ps1=pd47 consumer must not inherit the killed producer tag.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 55, 1, 46, true, cookie++), false, true, 0,
                  make_uop(Kind::Csr, 4, 55, 1, 47, true, cookie++), false, true, 0,
                  "directed-d030-branch-producers");
    dispatch_one(make_uop(Kind::Alu, 2, 46, 1, 48, true, cookie++),
                 false, true, 0, "directed-d030-branch-survivor");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 55;
    step("directed-d030-branch-arm-producers");
    idle_controls(); top->flush_en = 1; top->flush_tag = 3;
    step("directed-d030-branch-capture-flush");
    {
        const int before_failures = failures;
        idle_controls();
        set_dispatch(0, make_uop(Kind::Alu, 5, 47, 1, 49, true, cookie++),
                     false, true, 0);
        step("directed-d030-branch-survivor-select-and-reuse");
        if (failures == before_failures) cov.branch_flush_survivor_q = true;
    }
    {
        const int before_failures = failures;
        idle_step("directed-d030-branch-stale-must-block");
        int waiters = 0;
        for (const Entry& e : model)
            if (e.valid && !e.issued && (!e.r1 || !e.r2)) ++waiters;
        const bool blocked_and_resident = live_count() == 1 && waiters == 1;
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 47;
        step("directed-d030-branch-stale-real-wake");
        idle_step("directed-d030-branch-stale-select");
        if (failures == before_failures && blocked_and_resident
            && live_count() == 0)
            cov.stale_q_blocked_branch_flush = true;
    }

    // A token already active on the branch-flush edge must still persist into
    // an older survivor. Source1 wakes first; source2 remains blocked until
    // after q60 has expired, so the final select depends on that persistence.
    reset_dut(0);
    dispatch_one(make_uop(Kind::Alu, 2, 60, 61, 50, true, cookie++),
                 false, false, 0, "directed-d030-branch-active-q-survivor");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 60;
    step("directed-d030-branch-active-q-arm");
    idle_controls(); top->flush_en = 1; top->flush_tag = 3;
    step("directed-d030-branch-active-q-flush-persist");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 61;
    step("directed-d030-branch-active-q-second-source");
    {
        const int before_failures = failures;
        idle_step("directed-d030-branch-active-q-select");
        if (failures == before_failures && live_count() == 0)
            cov.branch_flush_active_q_persist = true;
    }

    // Asynchronous reset while a combinational selection is live.
    reset_dut(0);
    dispatch_one(make_uop(Kind::Alu, 1, 1, 2, 40, true, cookie++),
                 true, true, 0, "directed-reset-fill");
    idle_controls(); top->clk = 0; top->eval();
    if (golden_decision().idx[0] >= 0 && top->sel0_v) cov.reset_with_select = true;
    reset_dut(0);
    idle_step("directed-reset-empty");

    // D030 asynchronous reset must clear all active wake-token valids.
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 1, 1, 2, 50, true, cookie++), true, true, 0,
                  make_uop(Kind::Csr, 2, 1, 2, 51, true, cookie++), true, true, 0,
                  "directed-d030-reset-token-producers");
    idle_controls(); top->wkl_en = 1; top->wkl_tag = 52;
    step("directed-d030-reset-token-capture");
    reset_dut(0);
    dispatch_pair(make_uop(Kind::Alu, 3, 50, 52, 53, true, cookie++), false, false, 0,
                  make_uop(Kind::Csr, 4, 51, 1, 54, true, cookie++), false, true, 0,
                  "directed-d030-reset-token-reuse");
    {
        const int before_failures = failures;
        idle_step("directed-d030-reset-token-must-block");
        int waiters = 0;
        for (const Entry& e : model)
            if (e.valid && !e.issued && (!e.r1 || !e.r2)) ++waiters;
        const bool blocked_and_resident = live_count() == 2 && waiters == 2;
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 51;
        step("directed-d030-reset-token-real-wake-c1");
        idle_step("directed-d030-reset-token-select-c1");
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 50;
        step("directed-d030-reset-token-real-wake-c0-r1");
        idle_controls(); top->wkl_en = 1; top->wkl_tag = 52;
        step("directed-d030-reset-token-real-wake-c0-r2");
        idle_step("directed-d030-reset-token-select-c0");
        if (failures == before_failures && blocked_and_resident
            && live_count() == 0)
            cov.stale_q_blocked_reset = true;
    }
}

bool model_has_tag(uint8_t t) {
    for (const Entry& e : model)
        if (e.valid && tag(e.u) == t) return true;
    return false;
}

std::vector<int> waiting_entries() {
    std::vector<int> result;
    for (int i = 0; i < IQD; ++i)
        if (model[i].valid && !model[i].issued && (!model[i].r1 || !model[i].r2))
            result.push_back(i);
    return result;
}

std::vector<int> issued_loads() {
    std::vector<int> result;
    for (int i = 0; i < IQD; ++i)
        if (model[i].valid && model[i].issued && is_load(model[i].u))
            result.push_back(i);
    return result;
}

Kind random_kind() {
    const uint32_t r = rnd() % 100;
    if (r < 48) return Kind::Alu;
    if (r < 58) return Kind::Ctrl;
    if (r < 68) return Kind::Csr;
    if (r < 87) return Kind::Load;
    return Kind::Store;
}

Uop random_uop(Kind kind, uint8_t t, uint8_t pd_value, uint32_t cookie,
               uint8_t forced_ps1 = 0, bool force_ps1 = false) {
    uint8_t s1 = static_cast<uint8_t>(1 + (rnd() % 63));
    uint8_t s2 = static_cast<uint8_t>(1 + (rnd() % 63));
    if (force_ps1) s1 = forced_ps1;
    bool wr = kind != Kind::Store;
    if (kind == Kind::Ctrl && (rnd() & 3u) == 0) wr = false;
    return make_uop(kind, t, s1, s2, pd_value, wr, cookie);
}

void random_phase() {
    reset_dut(57, 0xff);
    uint8_t rob_tail = env_head;
    uint32_t cookie = 0x80000000u;

    for (int rc = 0; rc < RANDOM_CYCLES; ++rc) {
        // Retire one non-IQ head opportunistically.  A resident IQ entry at the
        // head conservatively blocks the synthetic ROB from advancing.
        uint8_t rob_count = age6(rob_tail, env_head);
        if (rob_count != 0 && !model_has_tag(env_head) && (rnd() & 3u) == 0)
            env_head = static_cast<uint8_t>((env_head + 1u) & 63u);
        rob_count = age6(rob_tail, env_head);

        idle_controls();

        // SQ unknown-address transitions: raw remains a one-cycle superset on
        // a clear, exactly like the same-cycle fill bypass in the full core.
        env_sq_unknown = env_sq_unknown_raw;
        if ((rnd() & 7u) == 0) {
            const uint8_t b = static_cast<uint8_t>(1u << (rnd() & 7u));
            if (env_sq_unknown_raw & b) {
                env_sq_unknown = static_cast<uint8_t>(env_sq_unknown_raw & ~b);
            } else {
                env_sq_unknown_raw = static_cast<uint8_t>(env_sq_unknown_raw | b);
                env_sq_unknown = env_sq_unknown_raw;
            }
        }
        sync_environment();

        bool do_full = (rnd() % 701u) == 0;
        bool do_branch = !do_full && rob_count != 0 && (rnd() % 401u) == 0;
        uint8_t branch_tag = env_head;
        if (do_branch) {
            branch_tag = static_cast<uint8_t>((env_head + (rnd() % rob_count)) & 63u);
            top->flush_en = 1;
            top->flush_tag = branch_tag;
        }
        if (do_full) top->flush_all = 1;

        // External load wake: usually target a genuinely waiting operand.
        const std::vector<int> waiting = waiting_entries();
        if (!waiting.empty() && (rnd() & 3u) == 0) {
            const Entry& e = model[waiting[rnd() % waiting.size()]];
            top->wkl_en = 1;
            top->wkl_tag = !e.r1 ? ps1(e.u) : ps2(e.u);
        } else if ((rnd() & 31u) == 0) {
            top->wkl_en = 1;
            top->wkl_tag = rnd() & 63u;
        }

        // Complete or replay a previously emitted load.  These controls are
        // legal public events except for the deliberate both-high collision,
        // whose current priority is part of the contract.
        const std::vector<int> loads = issued_loads();
        if (!loads.empty() && (rnd() & 1u) == 0) {
            const uint8_t t = tag(model[loads[rnd() % loads.size()]].u);
            const uint32_t action = rnd() & 15u;
            if (action < 6) { top->ldone_en = 1; top->ldone_tag = t; }
            else if (action < 14) { top->rep_en = 1; top->rep_tag = t; }
            else {
                top->rep_en = 1; top->rep_tag = t;
                top->ldone_en = 1; top->ldone_tag = t;
            }
        }

        int ndisp = 0;
        if (!do_full && !do_branch) {
            const int free = IQD - live_count();
            const int rob_space = 32 - rob_count;
            const int max_disp = free < rob_space ? free : rob_space;
            if (max_disp > 0 && (rnd() & 1u)) {
                ndisp = 1;
                if (max_disp > 1 && (rnd() & 1u)) ndisp = 2;
            }
        }

        Uop u0{}, u1{};
        Kind k0 = Kind::Alu, k1 = Kind::Alu;
        bool r10 = false, r20 = false, r11 = false, r21 = false;
        uint8_t m0 = 0, m1 = 0;
        if (ndisp >= 1) {
            k0 = random_kind();
            const uint8_t t0 = rob_tail;
            const uint8_t dest0 = static_cast<uint8_t>(32u + (t0 & 31u));
            u0 = random_uop(k0, t0, dest0, cookie++);
            r10 = (rnd() & 3u) != 0;
            r20 = (rnd() & 3u) != 0;
            if (k0 == Kind::Load || k0 == Kind::Store)
                m0 = static_cast<uint8_t>(rnd() & env_sq_unknown);
            set_dispatch(0, u0, r10, r20, m0);
        }
        if (ndisp == 2) {
            k1 = random_kind();
            const uint8_t t1 = static_cast<uint8_t>((rob_tail + 1u) & 63u);
            const uint8_t dest1 = static_cast<uint8_t>(32u + (t1 & 31u));
            const bool pair_dep = writes(u0) && (rnd() & 7u) == 0;
            u1 = random_uop(k1, t1, dest1, cookie++, pd(u0), pair_dep);
            r11 = pair_dep ? false : ((rnd() & 3u) != 0);
            r21 = (rnd() & 3u) != 0;
            if (k1 == Kind::Load || k1 == Kind::Store)
                m1 = static_cast<uint8_t>(rnd() & env_sq_unknown);
            set_dispatch(1, u1, r11, r21, m1);
        }

        step("random");

        if (do_full) rob_tail = env_head;
        else if (do_branch) rob_tail = static_cast<uint8_t>((branch_tag + 1u) & 63u);
        else rob_tail = static_cast<uint8_t>((rob_tail + ndisp) & 63u);

        // Raw SQ state catches up after the mask-decay edge.
        env_sq_unknown_raw = env_sq_unknown;
    }
    idle_step("random-final");
}

void require(bool condition, const char* name) {
    if (!condition) fail("coverage", name, 0, 1);
}

void check_required_coverage() {
    const int before = failures;
    for (int i = 0; i <= IQD; ++i) {
        char name[48]; std::snprintf(name, sizeof(name), "occupancy-%d", i);
        require(cov.occ[i], name);
    }
    for (int w = 0; w <= 2; ++w) {
        char name[48]; std::snprintf(name, sizeof(name), "dispatch-width-%d", w);
        require(cov.dispatch_width[w], name);
    }
    for (int p = 0; p < 3; ++p)
        for (int i = 0; i < IQD; ++i) {
            char name[48]; std::snprintf(name, sizeof(name), "port%d-winner-%d", p, i);
            require(cov.winner[p][i], name);
        }
    require(cov.final_slot, "final-slot allocation");
    require(cov.full_with_select, "full IQ with selection");
    require(cov.simultaneous_dispatch_select, "dispatch plus select");
    require(cov.all_three, "all three ports");
    require(cov.port0_ctrl, "port0 control priority");
    require(cov.port0_fallback, "port0 ALU fallback");
    require(cov.port1_second, "port1 second-oldest exclusion");
    require(cov.port1_csr, "CSR on port1");
    require(cov.age_wrap, "ROB age wrap");
    require(cov.age_tie, "lower-index age tie");
    require(cov.wkl, "external load wake");
    require(cov.wk0, "port0 select wake");
    require(cov.wk1, "port1 select wake");
    require(cov.wake_both_operands, "two-operand select wake");
    require(cov.dispatch_wake, "dispatch on wake-capture edge");
    for (int s = 0; s < 3; ++s)
        for (int op = 0; op < 2; ++op) {
            char name[64];
            std::snprintf(name, sizeof(name), "captured-wake-source%d-operand%d",
                          s, op + 1);
            require(cov.wake_q_apply[s][op], name);
        }
    require(cov.wake_q_all3_same_edge, "all three wake tokens captured together");
    require(cov.wake_q_direct_select, "captured wake selects next cycle");
    require(cov.wake_q_persist, "captured wake persists into stored readiness");
    require(cov.branch_flush_survivor_q, "branch survivor consumes captured wake");
    require(cov.branch_flush_active_q_persist,
            "active captured wake persists through branch flush");
    require(cov.stale_q_blocked_full_flush, "full-flush stale wake blocked");
    require(cov.stale_q_blocked_branch_flush, "branch-flush stale wake blocked");
    require(cov.stale_q_blocked_reset, "reset stale wake blocked");
    for (int b = 0; b < 8; ++b) {
        char name[48]; std::snprintf(name, sizeof(name), "wait-mask-bit-%d", b);
        require(cov.mask_bit[b], name);
    }
    require(cov.mask_multi, "multi-bit wait mask");
    require(cov.mask_block, "ready memory op blocked by mask");
    require(cov.mask_decay, "wait-mask decay");
    require(cov.load_issue, "load issue reservation");
    require(cov.load_held, "issued load cannot double-select");
    require(cov.replay, "load replay");
    require(cov.done, "load done");
    require(cov.replay_done, "same-cycle replay and done");
    require(cov.branch_flush, "branch flush");
    require(cov.full_flush, "full flush");
    require(cov.alloc_flush, "same-edge allocation plus flush");
    require(cov.select_flush, "selection in flush cycle");
    require(cov.reset_with_select, "reset with live selection");
    require(payload_checks != 0, "word-for-word payload checks");

    if (failures == before) {
        std::printf("iq-tb: mandatory coverage bins PASS "
                    "(occ 0..16, dispatch 0/1/2, winners 3x16, age/wakeup/"
                    "D030-retime/mask/replay/flush/reset)\n");
    }
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vooo_iq;

    directed_phase();
    const uint64_t directed_cycles = cycles;
    if (failures == 0)
        std::printf("iq-tb: directed phase clean (%llu cycles)\n",
                    static_cast<unsigned long long>(directed_cycles));

    random_phase();
    check_required_coverage();

    std::printf("iq-tb: %s (%d failures, %llu total cycles, %d random, "
                "%llu payload checks, selects=%llu/%llu/%llu)\n",
                failures == 0 ? "PASS" : "FAIL", failures,
                static_cast<unsigned long long>(cycles), RANDOM_CYCLES,
                static_cast<unsigned long long>(payload_checks),
                static_cast<unsigned long long>(selects[0]),
                static_cast<unsigned long long>(selects[1]),
                static_cast<unsigned long long>(selects[2]));

    top->final();
    delete top;
    return failures ? 1 : 0;
}
