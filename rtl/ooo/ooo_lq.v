// ============================================================================
// ooo_lq — 8-entry load queue for speculative loads (decision D020)
//
// Purpose:  With speculative loads, a load may issue BEFORE all older store
//           addresses are known (relaxing the conservative IQ mask gate). The
//           load queue records every in-flight load's address once it
//           executes, so that when an OLDER store later computes its address
//           we can detect a memory-ordering VIOLATION: a younger load that
//           already read a now-stale value. On a hit the top poisons that
//           load's ROB entry; it is squashed + replayed via flush-at-head
//           (docs/LQ.md, no per-load checkpoint needed).
//
// Lifecycle (per entry):
//   * alloc  at DISPATCH, in program order (slot0 older than slot1). The
//     load's ROB tag is its age key.
//   * execute: when the load performs its port2 read, it sets `executed` and
//     captures its word address + byte mask.
//   * dealloc at RETIRE (freed in order) or on a squash (flush/violation).
//
// Violation check (combinational, driven by the single port2 store fill):
//   a store filling word-address SA at store-tag ST violates every LQ entry
//   that is valid, executed, YOUNGER than ST (is_younger in modular ROB-tag
//   arithmetic), same word address, and whose byte mask intersects the
//   store's. At most one store fills per cycle (port2 is the sole mem pipe),
//   so one CAM sweep per cycle. The oldest such younger load is reported
//   (its ROB tag) — poisoning the oldest violator is sufficient because the
//   flush-at-head squashes it AND everything younger.
//
// Age:      6-bit ROB tags {phase, idx}; "A older than B" =
//           (A - head_tag) < (B - head_tag), same convention as the ROB/IQ.
// ============================================================================
`include "ooo_uop.vh"

module ooo_lq (
    input  wire        clk,
    input  wire        reset,

    input  wire [5:0]  head_tag,          // ROB head tag (age reference)

    // allocation at dispatch (0..2 loads this cycle, program order)
    input  wire        alloc0_en,
    input  wire [5:0]  alloc0_tag,        // load's ROB tag
    input  wire        alloc1_en,
    input  wire [5:0]  alloc1_tag,
    output wire        free_ge1,
    output wire        free_ge2,

    // execute: a load performed its read this cycle (port2 EX). Matches an
    // allocated entry by ROB tag and records its address + byte mask.
    input  wire        exec_en,
    input  wire [5:0]  exec_tag,
    input  wire [29:0] exec_waddr,        // addr[31:2]
    input  wire [3:0]  exec_bytemask,     // bytes consumed by the load

    // store address fill (port2 EX). Drives the violation CAM.
    input  wire        st_fill_en,
    input  wire [5:0]  st_tag,            // the store's ROB tag
    input  wire [29:0] st_waddr,
    input  wire [3:0]  st_bytemask,

    // violation output (combinational): the OLDEST younger executed load that
    // overlaps the filling store. The top poisons vio_tag's ROB entry.
    output wire        vio_en,
    output wire [5:0]  vio_tag,

    // retire: free the oldest entry/entries in program order (<=2/cycle)
    input  wire        retire0_en,
    input  wire [5:0]  retire0_tag,
    input  wire        retire1_en,
    input  wire [5:0]  retire1_tag,

    // squash: kill entries strictly younger than flush_tag (branch mispredict
    // or violation flush). Same predicate as the ROB/IQ.
    input  wire        flush_en,
    input  wire [5:0]  flush_tag,
    // full flush (violation reached head): clear everything.
    input  wire        flush_all
);

`include "ooo_pkg.vh"

    reg              v        [0:LQD-1];
    reg              executed [0:LQD-1];
    reg  [5:0]       tag      [0:LQD-1];
    reg  [29:0]      waddr    [0:LQD-1];
    reg  [3:0]       bmask    [0:LQD-1];

    integer i;

    // ------------------------------------------------------------------
    // occupancy / free slots (simple valid-count over the small array)
    // ------------------------------------------------------------------
    reg [3:0] occ;
    always @(*) begin
        occ = 4'd0;
        for (i = 0; i < LQD; i = i + 1)
            if (v[i]) occ = occ + 4'd1;
    end
    assign free_ge1 = (occ <  LQD);
    assign free_ge2 = (occ <  LQD - 1);

    // free-slot indices (lowest-index-first, from registered v[])
    reg [LQW-1:0] free0, free1;
    reg           f0v, f1v;
    always @(*) begin
        f0v = 1'b0; f1v = 1'b0; free0 = {LQW{1'b0}}; free1 = {LQW{1'b0}};
        for (i = LQD - 1; i >= 0; i = i - 1)
            if (!v[i]) begin
                free1 = free0; f1v = f0v;
                free0 = i[LQW-1:0]; f0v = 1'b1;
            end
    end

    // Pack load allocations independent of their decode slot.  If slot0 is
    // not a load and slot1 is, slot1 must consume the FIRST free LQ entry.
    // Using free1 unconditionally drops that load at occupancy=7 (B015).
    wire [LQW-1:0] alloc1_slot = alloc0_en ? free1 : free0;
    wire           alloc1_slot_v = alloc0_en ? f1v : f0v;

    // ------------------------------------------------------------------
    // Violation CAM + balanced oldest-match reduction (D026).
    //
    // The original implementation accumulated the minimum age in a for-loop.
    // Quartus preserved that source-order dependency as an 8-deep compare/mux
    // chain on the dmem-load -> dependent-store -> rob_poison critical path.
    // Build all eight match tuples in parallel, then reduce them through a
    // fixed 8 -> 4 -> 2 -> 1 tree.  This is cycle- and bit-exact:
    //   tuple = {valid_match, age_from_head, ROB_tag}
    //   winner = smallest age; on an equal-age tie, the lower LQ index wins
    //            (the same first-match behavior as the old 0..7 scan).
    // In-flight ROB tags are unique, so the tie rule is defensive rather than
    // architecturally observable.  No-match still drives vio_tag=0 exactly as
    // before.
    // ------------------------------------------------------------------
    function [12:0] oldest_of_two;
        input [12:0] left;
        input [12:0] right;
        begin
            if (!left[12])
                oldest_of_two = right;
            else if (right[12] && (left[11:6] > right[11:6]))
                oldest_of_two = right;
            else
                oldest_of_two = left;
        end
    endfunction

    wire [5:0] vio_st_age;
    wire [5:0] vio_age  [0:LQD-1];
    wire       vio_hit  [0:LQD-1];
    wire [12:0] vio_cand [0:LQD-1];

    assign vio_st_age = st_tag - head_tag;

    genvar vg;
    generate for (vg = 0; vg < LQD; vg = vg + 1) begin : GEN_VIO_CAND
        assign vio_age[vg] = tag[vg] - head_tag;
        assign vio_hit[vg] = st_fill_en
                           && v[vg]
                           && executed[vg]
                           && (vio_age[vg] > vio_st_age)
                           && (waddr[vg] == st_waddr)
                           && ((bmask[vg] & st_bytemask) != 4'b0);
        assign vio_cand[vg] = {vio_hit[vg], vio_age[vg], tag[vg]};
    end endgenerate

    wire [12:0] vio_l1 [0:3];
    wire [12:0] vio_l2 [0:1];
    wire [12:0] vio_winner;

    assign vio_l1[0] = oldest_of_two(vio_cand[0], vio_cand[1]);
    assign vio_l1[1] = oldest_of_two(vio_cand[2], vio_cand[3]);
    assign vio_l1[2] = oldest_of_two(vio_cand[4], vio_cand[5]);
    assign vio_l1[3] = oldest_of_two(vio_cand[6], vio_cand[7]);
    assign vio_l2[0] = oldest_of_two(vio_l1[0], vio_l1[1]);
    assign vio_l2[1] = oldest_of_two(vio_l1[2], vio_l1[3]);
    assign vio_winner = oldest_of_two(vio_l2[0], vio_l2[1]);

    assign vio_en  = vio_winner[12];
    assign vio_tag = vio_winner[12] ? vio_winner[5:0] : 6'd0;

`ifdef VERILATOR
    initial if (LQD != 8)
        $fatal(1, "ooo_lq: fixed violation tree requires LQD=8 (got %0d)",
               LQD);

    // INV-L1: the balanced tree must remain exactly equivalent to the original
    // source-order scan.  Keep this deliberately separate from the tree so
    // every full-core and standalone Verilator run is a live equivalence test.
    reg       vio_ref_en;
    reg [5:0] vio_ref_age;
    reg [5:0] vio_ref_tag;
    integer   vio_ref_i;
    always @(*) begin
        vio_ref_en  = 1'b0;
        vio_ref_age = 6'd63;
        vio_ref_tag = 6'd0;
        if (st_fill_en) begin
            for (vio_ref_i = 0; vio_ref_i < LQD;
                 vio_ref_i = vio_ref_i + 1) begin
                if (v[vio_ref_i] && executed[vio_ref_i]
                    && ((tag[vio_ref_i] - head_tag)
                        > (st_tag - head_tag))
                    && (waddr[vio_ref_i] == st_waddr)
                    && ((bmask[vio_ref_i] & st_bytemask) != 4'b0)) begin
                    if (!vio_ref_en
                        || ((tag[vio_ref_i] - head_tag) < vio_ref_age)) begin
                        vio_ref_en  = 1'b1;
                        vio_ref_age = tag[vio_ref_i] - head_tag;
                        vio_ref_tag = tag[vio_ref_i];
                    end
                end
            end
        end
    end

    integer vio_inv_i;
    integer vio_inv_j;
    always @(posedge clk) if (!reset) begin
        if ((vio_en !== vio_ref_en) || (vio_tag !== vio_ref_tag))
            $fatal(1, "ooo_lq INV-L1: tree=%b/%0d scan=%b/%0d",
                   vio_en, vio_tag, vio_ref_en, vio_ref_tag);

        // INV-L2: ROB tags identify unique in-flight instructions. Duplicate
        // valid tags would make both execute matching and age selection
        // ambiguous, independent of the tree implementation.
        for (vio_inv_i = 0; vio_inv_i < LQD; vio_inv_i = vio_inv_i + 1)
            for (vio_inv_j = vio_inv_i + 1; vio_inv_j < LQD;
                 vio_inv_j = vio_inv_j + 1)
                if (v[vio_inv_i] && v[vio_inv_j]
                    && (tag[vio_inv_i] == tag[vio_inv_j]))
                    $fatal(1, "ooo_lq INV-L2: duplicate live ROB tag %0d",
                           tag[vio_inv_i]);

        // INV-L3: dispatch resource checks must never request more load
        // entries than exist. This also keeps a future packing regression
        // from becoming another silently untracked speculative load.
        if (alloc0_en && !f0v)
            $fatal(1, "ooo_lq INV-L3: alloc0 requested with no free entry");
        if (alloc1_en && !alloc1_slot_v)
            $fatal(1, "ooo_lq INV-L3: alloc1 requested without a packed slot");
    end
`endif

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < LQD; i = i + 1) begin
                v[i] <= 1'b0; executed[i] <= 1'b0;
                tag[i] <= 6'b0; waddr[i] <= 30'b0; bmask[i] <= 4'b0;
            end
        end else begin
            // execute: record address+mask on the matching allocated entry
            if (exec_en) begin
                for (i = 0; i < LQD; i = i + 1)
                    if (v[i] && (tag[i] == exec_tag)) begin
                        executed[i] <= 1'b1;
                        waddr[i]    <= exec_waddr;
                        bmask[i]    <= exec_bytemask;
                    end
            end

            // retire: free by ROB tag (in order)
            if (retire0_en)
                for (i = 0; i < LQD; i = i + 1)
                    if (v[i] && (tag[i] == retire0_tag)) v[i] <= 1'b0;
            if (retire1_en)
                for (i = 0; i < LQD; i = i + 1)
                    if (v[i] && (tag[i] == retire1_tag)) v[i] <= 1'b0;

            // allocation (0..2 at the lowest free slots)
            if (alloc0_en && f0v) begin
                v[free0]        <= 1'b1;
                executed[free0] <= 1'b0;
                tag[free0]      <= alloc0_tag;
            end
            if (alloc1_en && alloc1_slot_v) begin
                v[alloc1_slot]        <= 1'b1;
                executed[alloc1_slot] <= 1'b0;
                tag[alloc1_slot]      <= alloc1_tag;
            end

            // squash LAST (overrides alloc of dying entries)
            if (flush_all) begin
                for (i = 0; i < LQD; i = i + 1) v[i] <= 1'b0;
            end else if (flush_en) begin
                for (i = 0; i < LQD; i = i + 1)
                    if (v[i] && ((tag[i] - head_tag) > (flush_tag - head_tag)))
                        v[i] <= 1'b0;
                if (alloc0_en && f0v) v[free0] <= 1'b0;
                if (alloc1_en && alloc1_slot_v) v[alloc1_slot] <= 1'b0;
            end
        end
    end

endmodule
