// ============================================================================
// sq_tb.cpp — standalone Verilator unit testbench for ooo_sq (D027)
//
// Public-interface golden model for the full 8-entry SQ lifecycle and its
// combinational load query.  The model deliberately knows nothing about the
// selector's RTL topology.  It reproduces the architectural contract:
//   * four-bit modulo tags are ordered relative to the current SQ head;
//   * any older buffered store sets q_older, even if its address is unknown;
//   * the youngest older known store to the same word decides the query;
//   * SW forwards, while SB/SH force replay; no match drives q_data=0;
//   * query/drain outputs observe pre-edge state, including on fill/flush;
//   * allocation, fill, commit, drain, and flush use RTL NBA priorities.
//
// Directed cases cover strict ordering, unknown-address ordering, full-word
// forwarding, partial-store replay, multiple matches, pointer wrap, drain
// backpressure, same-edge visibility, branch rewind, violation rewind, and
// wrong-path same-cycle allocation suppression.  A deterministic 300k-cycle
// phase then mixes every legal operation while checking every public output.
//
// Build/run: make sq-tb
// ============================================================================
#include <cstdio>
#include <cstdint>

#include "Vooo_sq.h"
#include "verilated.h"

double sc_time_stamp() { return 0.0; }

namespace {

struct Entry {
    bool     valid;
    bool     known;
    bool     committed;
    uint8_t  tag;
    uint32_t addr;
    uint32_t data;
    uint8_t  f3;
};

Vooo_sq* top;
Entry    model[8];
uint8_t  g_head = 0;
uint8_t  g_tail = 0;
uint8_t  g_cptr = 0;
uint64_t cycles = 0;
uint64_t queries = 0;
uint64_t forwards = 0;
uint64_t conflicts = 0;
uint64_t drains = 0;
uint64_t flushes = 0;
uint64_t occ_seen[9] = {};
uint64_t alloc1_seen = 0;
uint64_t alloc2_seen = 0;
uint64_t final_slot_seen = 0;
uint64_t fill_width_seen[3] = {};
uint64_t no_match_seen = 0;
uint64_t ordered_no_match_seen = 0;
uint64_t multi_match_seen = 0;
uint64_t backpressure_seen = 0;
uint64_t fire_seen = 0;
uint64_t branch_flush_seen = 0;
uint64_t full_flush_seen = 0;
uint64_t alloc_flush_seen = 0;
uint64_t retire_drain_seen = 0;
uint64_t pointer_wrap_seen = 0;
uint64_t winner_leaf_seen[8] = {};
int      failures = 0;

uint32_t rng_state = 0xD027D027u;
uint32_t rnd() {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return rng_state = x;
}

uint8_t age4(uint8_t tag, uint8_t head) {
    return static_cast<uint8_t>((tag - head) & 15u);
}

int occupancy() {
    return age4(g_tail, g_head);
}

int committed_count() {
    return age4(g_cptr, g_head);
}

void clear_model() {
    for (Entry& e : model) e = {false, false, false, 0, 0, 0, 0};
    g_head = g_tail = g_cptr = 0;
}

void idle_controls() {
    top->alloc_n = 0;
    top->fill_en = 0;
    top->fill_pos = 0;
    top->fill_tag4 = 0;
    top->fill_addr = 0;
    top->fill_data = 0;
    top->fill_f3 = 0;
    top->retire_mark_en = 0;
    top->mw_ready = 1;
    top->q_addr = 0;
    top->q_color4 = 0;
    top->q_valid = 0;
    top->flush_en = 0;
    top->flush_tail4 = 0;
}

void dump_state() {
    std::printf("  head=%u tail=%u cptr=%u occ=%d committed=%d\n",
                unsigned(g_head), unsigned(g_tail), unsigned(g_cptr),
                occupancy(), committed_count());
    for (int i = 0; i < 8; ++i) {
        const Entry& e = model[i];
        std::printf("  sq[%d] v=%u k=%u c=%u tag=%u age=%u "
                    "addr=%08x data=%08x f3=%u\n",
                    i, e.valid, e.known, e.committed, unsigned(e.tag),
                    unsigned(age4(e.tag, g_head)), unsigned(e.addr),
                    unsigned(e.data), unsigned(e.f3));
    }
}

void fail_value(const char* phase, const char* what,
                uint64_t got, uint64_t want) {
    if (failures < 20) {
        std::printf("FAIL %s cycle=%llu %s: got=0x%llx want=0x%llx\n",
                    phase, static_cast<unsigned long long>(cycles), what,
                    static_cast<unsigned long long>(got),
                    static_cast<unsigned long long>(want));
        dump_state();
    }
    ++failures;
}

void expect_eq(const char* phase, const char* what,
               uint64_t got, uint64_t want) {
    if (got != want) fail_value(phase, what, got, want);
}

struct QueryResult {
    bool     hit;
    uint32_t data;
    bool     conflict;
    bool     older;
    int      matches;
    int      winner_index;
};

QueryResult golden_query() {
    QueryResult q = {false, 0, false, false, 0, -1};
    bool found = false;
    uint8_t best_age = 0;
    bool best_word = false;
    const uint8_t color_age = age4(top->q_color4 & 15u, g_head);

    for (int i = 0; i < 8; ++i) {
        const Entry& e = model[i];
        const uint8_t store_age = age4(e.tag, g_head);
        const bool older = e.valid && store_age < color_age;
        if (older) q.older = true;
        const bool match = older && e.known
                        && ((e.addr >> 2) == (uint32_t(top->q_addr) >> 2));
        if (match) ++q.matches;
        if (match && (!found || store_age > best_age)) {
            found = true;
            best_age = store_age;
            q.data = e.data;
            best_word = (e.f3 & 3u) == 2u;
            q.winner_index = i;
        }
    }
    q.hit = found && best_word;
    q.conflict = found && !best_word;
    if (!found) q.data = 0;
    return q;
}

void check_comb(const char* phase) {
    top->eval();
    const int occ = occupancy();
    const uint8_t hidx = g_head & 7u;
    const bool exp_mw_valid = occ != 0
                           && model[hidx].valid
                           && model[hidx].committed;

    expect_eq(phase, "free_ge1", top->free_ge1, occ < 8);
    expect_eq(phase, "free_ge2", top->free_ge2, occ < 7);
    expect_eq(phase, "tail4", top->tail4, g_tail);
    expect_eq(phase, "commit_tail4", top->commit_tail4, g_cptr);
    expect_eq(phase, "sq_empty", top->sq_empty, occ == 0);
    expect_eq(phase, "mw_valid", top->mw_valid, exp_mw_valid);
    expect_eq(phase, "mw_addr", top->mw_addr, model[hidx].addr);
    expect_eq(phase, "mw_data", top->mw_data, model[hidx].data);
    expect_eq(phase, "mw_f3", top->mw_f3, model[hidx].f3);

    uint8_t exp_raw = 0;
    uint8_t exp_byp = 0;
    for (int i = 0; i < 8; ++i) {
        const bool raw = model[i].valid && !model[i].known;
        const bool byp = raw && !(top->fill_en && top->fill_pos == i);
        if (raw) exp_raw |= uint8_t(1u << i);
        if (byp) exp_byp |= uint8_t(1u << i);
    }
    expect_eq(phase, "unknown_raw", top->unknown_raw, exp_raw);
    expect_eq(phase, "unknown_mask", top->unknown_mask, exp_byp);

    const QueryResult q = golden_query();
    expect_eq(phase, "q_hit", top->q_hit, q.hit);
    expect_eq(phase, "q_data", top->q_data, q.data);
    expect_eq(phase, "q_conflict", top->q_conflict, q.conflict);
    expect_eq(phase, "q_older", top->q_older, q.older);
    ++queries;
    if (q.hit) ++forwards;
    if (q.conflict) ++conflicts;
    if (!q.hit && !q.conflict) ++no_match_seen;
    if (q.older && !q.hit && !q.conflict) ++ordered_no_match_seen;
    if (q.matches >= 2) ++multi_match_seen;
    if (q.winner_index >= 0) ++winner_leaf_seen[q.winner_index];

    if (occ >= 0 && occ <= 8) ++occ_seen[occ];
    if (top->alloc_n == 1) ++alloc1_seen;
    if (top->alloc_n == 2) ++alloc2_seen;
    if (occ == 7 && top->alloc_n == 1) ++final_slot_seen;
    if (top->fill_en && top->fill_f3 < 3)
        ++fill_width_seen[top->fill_f3];
    if (exp_mw_valid && !top->mw_ready) ++backpressure_seen;
    if (exp_mw_valid && top->mw_ready) ++fire_seen;
    if (top->flush_en) {
        if ((top->flush_tail4 & 15u) == g_cptr) ++full_flush_seen;
        else ++branch_flush_seen;
        if (top->alloc_n != 0) ++alloc_flush_seen;
    }
    if (top->retire_mark_en && exp_mw_valid && top->mw_ready)
        ++retire_drain_seen;
}

void model_next_edge() {
    Entry before[8];
    Entry next[8];
    for (int i = 0; i < 8; ++i) before[i] = next[i] = model[i];
    const uint8_t old_head = g_head;
    const uint8_t old_tail = g_tail;
    const uint8_t old_cptr = g_cptr;
    uint8_t next_head = old_head;
    uint8_t next_tail = old_tail;
    uint8_t next_cptr = old_cptr;
    const int old_occ = age4(old_tail, old_head);
    const uint8_t hidx = old_head & 7u;
    const bool pre_mw_valid = old_occ != 0
                           && before[hidx].valid
                           && before[hidx].committed;

    if (top->alloc_n != 0) {
        const uint8_t idx0 = old_tail & 7u;
        next[idx0].valid = true;
        next[idx0].known = false;
        next[idx0].committed = false;
        next[idx0].tag = old_tail;
        if (top->alloc_n == 2) {
            const uint8_t idx1 = (idx0 + 1u) & 7u;
            next[idx1].valid = true;
            next[idx1].known = false;
            next[idx1].committed = false;
            next[idx1].tag = (old_tail + 1u) & 15u;
        }
        next_tail = (old_tail + top->alloc_n) & 15u;
        if (next_tail < old_tail) ++pointer_wrap_seen;
    }

    if (top->fill_en) {
        Entry& e = next[top->fill_pos & 7u];
        e.known = true;
        e.addr = top->fill_addr;
        e.data = top->fill_data;
        e.f3 = top->fill_f3 & 7u;
    }

    if (top->retire_mark_en) {
        next[old_cptr & 7u].committed = true;
        next_cptr = (old_cptr + 1u) & 15u;
        if (next_cptr < old_cptr) ++pointer_wrap_seen;
    }

    if (pre_mw_valid && top->mw_ready) {
        next[hidx].valid = false;
        next_head = (old_head + 1u) & 15u;
        if (next_head < old_head) ++pointer_wrap_seen;
        ++drains;
    }

    if (top->flush_en) {
        next_tail = top->flush_tail4 & 15u;
        const uint8_t flush_age = age4(top->flush_tail4 & 15u, old_head);
        for (int i = 0; i < 8; ++i) {
            if (before[i].valid && !(age4(before[i].tag, old_head) < flush_age))
                next[i].valid = false;
        }
        if (top->alloc_n != 0) {
            next[old_tail & 7u].valid = false;
            if (top->alloc_n == 2)
                next[(old_tail + 1u) & 7u].valid = false;
        }
        ++flushes;
    }

    for (int i = 0; i < 8; ++i) model[i] = next[i];
    g_head = next_head;
    g_tail = next_tail;
    g_cptr = next_cptr;
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
    top->reset = 1;
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    top->clk = 0;
    top->reset = 0;
    top->eval();
}

uint8_t allocate(uint8_t count, const char* phase = "allocate") {
    const uint8_t first = g_tail & 7u;
    idle_controls();
    top->alloc_n = count;
    step(phase);
    return first;
}

void fill(uint8_t pos, uint32_t addr, uint32_t data, uint8_t f3,
          const char* phase = "fill") {
    idle_controls();
    top->fill_en = 1;
    top->fill_pos = pos;
    top->fill_tag4 = model[pos].tag;
    top->fill_addr = addr;
    top->fill_data = data;
    top->fill_f3 = f3;
    step(phase);
}

void set_query(uint8_t color, uint32_t addr) {
    top->q_valid = 1;
    top->q_color4 = color & 15u;
    top->q_addr = addr;
}

void probe(uint8_t color, uint32_t addr, bool hit, uint32_t data,
           bool conflict, bool older, const char* phase) {
    idle_controls();
    set_query(color, addr);
    top->eval();
    expect_eq(phase, "directed q_hit", top->q_hit, hit);
    expect_eq(phase, "directed q_data", top->q_data, data);
    expect_eq(phase, "directed q_conflict", top->q_conflict, conflict);
    expect_eq(phase, "directed q_older", top->q_older, older);
    step(phase);
}

void retire_mark(const char* phase = "retire-mark") {
    idle_controls();
    top->retire_mark_en = 1;
    step(phase);
}

void drain_head(const char* phase = "drain") {
    idle_controls();
    top->mw_ready = 1;
    step(phase);
}

int choose_unknown() {
    int choices[8];
    int n = 0;
    for (int i = 0; i < 8; ++i)
        if (model[i].valid && !model[i].known) choices[n++] = i;
    return n ? choices[rnd() % n] : -1;
}

int choose_known_older(uint8_t color) {
    int choices[8];
    int n = 0;
    const uint8_t color_age = age4(color, g_head);
    for (int i = 0; i < 8; ++i)
        if (model[i].valid && model[i].known
            && age4(model[i].tag, g_head) < color_age)
            choices[n++] = i;
    return n ? choices[rnd() % n] : -1;
}

void advance_empty_one(uint32_t salt) {
    const uint8_t pos = allocate(1, "advance-alloc");
    fill(pos, 0x1000u + salt * 4u, 0xA0000000u | salt, 2,
         "advance-fill");
    retire_mark("advance-retire");
    drain_head("advance-drain");
}

void check_required_coverage() {
    const int failures_before = failures;
    for (int occ = 0; occ <= 8; ++occ)
        if (occ_seen[occ] == 0)
            fail_value("coverage", "unseen occupancy", occ, 0xFFFFFFFFu);
    if (!alloc1_seen) fail_value("coverage", "alloc1", 0, 1);
    if (!alloc2_seen) fail_value("coverage", "alloc2", 0, 1);
    if (!final_slot_seen) fail_value("coverage", "final-slot alloc", 0, 1);
    for (int width = 0; width < 3; ++width)
        if (!fill_width_seen[width])
            fail_value("coverage", "store width", width, 0xFFFFFFFFu);
    if (!no_match_seen) fail_value("coverage", "no match", 0, 1);
    if (!ordered_no_match_seen)
        fail_value("coverage", "q_older without match", 0, 1);
    if (!multi_match_seen) fail_value("coverage", "multi-match", 0, 1);
    if (!backpressure_seen) fail_value("coverage", "backpressure", 0, 1);
    if (!fire_seen) fail_value("coverage", "drain fire", 0, 1);
    if (!branch_flush_seen) fail_value("coverage", "branch flush", 0, 1);
    if (!full_flush_seen) fail_value("coverage", "full flush", 0, 1);
    if (!alloc_flush_seen) fail_value("coverage", "alloc+flush", 0, 1);
    if (!retire_drain_seen) fail_value("coverage", "retire+drain", 0, 1);
    if (!pointer_wrap_seen) fail_value("coverage", "pointer wrap", 0, 1);
    for (int leaf = 0; leaf < 8; ++leaf)
        if (!winner_leaf_seen[leaf])
            fail_value("coverage", "unselected tree leaf", leaf,
                       0xFFFFFFFFu);
    if (failures == failures_before)
        std::printf("sq-tb: mandatory coverage bins PASS "
                    "(occupancy 0..8, widths, forwarding/replay, ordering, "
                    "drain, flush, wrap)\n");
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vooo_sq;
    reset_dut();

    // ---- directed query and lifecycle contract ------------------------
    step("reset-idle");

    // Prove every occupancy/free-flag boundary, including the legal final
    // single allocation at occupancy seven, before resetting via cptr flush.
    for (int occ = 0; occ < 8; ++occ)
        allocate(1, occ == 7 ? "final-slot-alloc" : "occupancy-walk");
    idle_controls();
    step("full-occupancy-observe");
    idle_controls();
    top->flush_en = 1;
    top->flush_tail4 = g_cptr;
    step("empty-uncommitted-full-queue");

    allocate(2, "alloc-two");
    allocate(1, "alloc-one");
    probe(3, 0x400, false, 0, false, true, "unknown-is-older");

    fill(0, 0x400, 0xAAAAAAAAu, 2, "fill-sw0");
    fill(1, 0x401, 0xBBBBBBBBu, 0, "fill-sb1-offset");
    fill(2, 0x400, 0xCCCCCCCCu, 2, "fill-sw2");
    probe(1, 0x400, true, 0xAAAAAAAAu, false, true,
          "strict-color-one");
    probe(2, 0x400, false, 0xBBBBBBBBu, true, true,
          "youngest-partial-conflict");
    probe(3, 0x400, true, 0xCCCCCCCCu, false, true,
          "youngest-full-forward");
    probe(1, 0x403, true, 0xAAAAAAAAu, false, true,
          "same-word-different-offset-forward");
    probe(2, 0x403, false, 0xBBBBBBBBu, true, true,
          "same-word-different-offset-conflict");
    probe(0, 0x400, false, 0, false, false, "equal-not-older");
    probe(3, 0x800, false, 0, false, true, "different-word-still-older");

    // Same-edge fill is hidden from the query's registered state, while
    // unknown_mask gets its intentional combinational fill bypass.
    const uint8_t p3 = allocate(1, "alloc-same-edge-fill");
    idle_controls();
    top->fill_en = 1;
    top->fill_pos = p3;
    top->fill_tag4 = model[p3].tag;
    top->fill_addr = 0x500;
    top->fill_data = 0xDDDDDDDDu;
    top->fill_f3 = 2;
    set_query(4, 0x500);
    top->eval();
    expect_eq("same-edge-fill", "pre-edge q_hit", top->q_hit, 0);
    expect_eq("same-edge-fill", "fill-bypass unknown bit",
              (top->unknown_mask >> p3) & 1u, 0);
    step("same-edge-fill");
    probe(4, 0x500, true, 0xDDDDDDDDu, false, true,
          "post-fill-visible");

    // Commit is visible one edge later; a ready-low drain holds all fields.
    retire_mark("commit-head0");
    idle_controls();
    top->mw_ready = 0;
    set_query(4, 0x400);
    top->eval();
    expect_eq("drain-hold", "mw_valid", top->mw_valid, 1);
    expect_eq("drain-hold", "mw_addr", top->mw_addr, 0x400);
    expect_eq("drain-hold", "mw_data", top->mw_data, 0xAAAAAAAAu);
    step("drain-hold");
    idle_controls();
    top->mw_ready = 1;
    top->retire_mark_en = 1;
    step("drain-head0-retire-head1");

    // Tag1 was committed while tag0 drained. Drain it, then retire/drain the
    // remaining two stores in program order.
    drain_head("drain-already-committed-head1");
    for (int n = 0; n < 2; ++n) {
        retire_mark("commit-next");
        drain_head("drain-next");
    }
    if (occupancy() != 0) fail_value("directed", "empty after drains",
                                      occupancy(), 0);

    // Move all three ring counters to 14, then allocate across 15 -> 0.
    for (int n = 0; n < 10; ++n) advance_empty_one(n);
    expect_eq("wrap-setup", "head", g_head, 14);
    expect_eq("wrap-setup", "tail", g_tail, 14);
    expect_eq("wrap-setup", "cptr", g_cptr, 14);
    allocate(2, "wrap-alloc-14-15");
    allocate(2, "wrap-alloc-0-1");
    fill(6, 0x900, 0x0000000Eu, 2, "wrap-fill14");
    fill(7, 0x900, 0x0000000Fu, 2, "wrap-fill15");
    fill(0, 0x900, 0x00000000u, 1, "wrap-fill0-partial");
    fill(1, 0x900, 0x00000001u, 2, "wrap-fill1");
    probe(2, 0x900, true, 0x00000001u, false, true,
          "wrap-youngest-tag1");
    probe(0, 0x900, true, 0x0000000Fu, false, true,
          "wrap-color0-excludes-tag0");

    // Commit tag14 but hold it. Branch rewind to tail0 keeps tags14/15 and
    // kills tags0/1 plus a same-cycle wrong-path allocation at old tail2.
    retire_mark("wrap-commit14");
    idle_controls();
    top->mw_ready = 0;
    top->alloc_n = 1;
    top->flush_en = 1;
    top->flush_tail4 = 0;
    step("branch-rewind-plus-allocation");
    expect_eq("branch-rewind", "tail", g_tail, 0);
    expect_eq("branch-rewind", "occupancy", occupancy(), 2);

    // Violation recovery rewinds to committed tail15: tag15 is uncommitted
    // and dies, while committed tag14 remains available to drain.
    idle_controls();
    top->mw_ready = 0;
    top->flush_en = 1;
    top->flush_tail4 = g_cptr;
    step("violation-rewind-to-cptr");
    expect_eq("violation-rewind", "tail", g_tail, 15);
    expect_eq("violation-rewind", "occupancy", occupancy(), 1);
    drain_head("drain-surviving-committed");
    expect_eq("directed-end", "empty", occupancy(), 0);

    if (failures == 0)
        std::printf("sq-tb: directed phase clean (%llu cycles)\n",
                    static_cast<unsigned long long>(cycles));

    // ---- constrained-random lifecycle + query phase -------------------
    reset_dut();
    for (int n = 0; n < 300000; ++n) {
        idle_controls();
        const int occ = occupancy();
        const int free = 8 - occ;

        // Allocation is capacity-legal in the pre-edge state. Occasionally
        // pair it with a flush to exercise wrong-path suppression.
        if (free > 0 && (rnd() & 3u) == 0) {
            top->alloc_n = (free >= 2 && (rnd() & 3u) == 0) ? 2 : 1;
        }

        const int fill_idx = choose_unknown();
        if (fill_idx >= 0 && (rnd() & 1u)) {
            top->fill_en = 1;
            top->fill_pos = fill_idx;
            top->fill_tag4 = model[fill_idx].tag;
            top->fill_addr = (rnd() & 63u) << 2;
            top->fill_data = rnd();
            top->fill_f3 = rnd() % 3u;
        }

        // A store retires only after its address/data are known and only at
        // cptr. This matches the ROB's in-order retirement contract.
        const uint8_t cidx = g_cptr & 7u;
        if (g_cptr != g_tail && model[cidx].valid && model[cidx].known
            && (rnd() & 7u) == 0) {
            top->retire_mark_en = 1;
        }

        top->mw_ready = (rnd() & 7u) != 0;

        if ((rnd() & 127u) == 0) {
            int min_keep = committed_count() + (top->retire_mark_en ? 1 : 0);
            if (min_keep <= occ) {
                const int keep = min_keep + int(rnd() % (occ - min_keep + 1));
                top->flush_en = 1;
                top->flush_tail4 = (g_head + keep) & 15u;
            }
        }

        // A live load color lies from head through tail. Reuse a known older
        // store's word half the time to create dense multi-match forwarding.
        const int color_age = occ == 0 ? 0 : int(rnd() % (occ + 1));
        const uint8_t color = (g_head + color_age) & 15u;
        top->q_valid = 1;
        top->q_color4 = color;
        const int seed = choose_known_older(color);
        if (seed >= 0 && (rnd() & 1u))
            top->q_addr = model[seed].addr;
        else
            top->q_addr = (rnd() & 63u) << 2;

        step("random");
    }

    check_comb("final");
    check_required_coverage();
    std::printf("sq-tb: %s (%d failures, %llu cycles, %llu queries, "
                "%llu forwards, %llu conflicts, %llu drains, %llu flushes)\n",
                failures == 0 ? "PASS" : "FAIL", failures,
                static_cast<unsigned long long>(cycles),
                static_cast<unsigned long long>(queries),
                static_cast<unsigned long long>(forwards),
                static_cast<unsigned long long>(conflicts),
                static_cast<unsigned long long>(drains),
                static_cast<unsigned long long>(flushes));
    delete top;
    return failures ? 1 : 0;
}
