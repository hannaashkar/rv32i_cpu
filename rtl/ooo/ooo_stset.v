// ============================================================================
// ooo_stset — store-set memory-dependence predictor (decision D021)
//
// Purpose:   Stops re-speculating a load once it has violated (Chrysos &
//            Emer, "Memory Dependence Prediction using Store Sets", ISCA
//            1998 — the Alpha 21464-lineage mechanism). Two tables:
//
//            * SSIT (Store Set ID Table): 2^SSIT_AW entries indexed by
//              pc[SSIT_AW+1:2], untagged; entry = {valid, ssid}. Maps both
//              loads and stores that have participated in a memory-ordering
//              violation to a common store-set ID.
//            * LFST (Last Fetched Store Table): 16 entries indexed by ssid;
//              entry = {valid, sqpos} = the SQ slot of the LAST DISPATCHED
//              store of that set. Deviation from the paper (which stores an
//              instruction number): naming the SQ slot lets the existing IQ
//              wait-mask machinery implement the wait — the top turns the
//              slot into a one-hot dispatch mask ANDed with the conservative
//              older-unknown-store mask, so a stale entry is either a legal
//              bounded wait or masked to 0 (speculate; the LQ violation CAM
//              repairs any real conflict). The paper's LFST invalidation-at-
//              store-execute is implicit: an executed store's sq_unknown bit
//              is already 0.
//
// Training:  on an LQ violation the top registers {load pc, store pc} and
//            asserts train_en for ONE cycle. The module reuses its two SSIT
//            lookup ports for the merge-rule reads that cycle (train_busy
//            tells the top to treat this cycle's predictions as "none" — a
//            free hint blackout inside the ~46-cycle violation flush).
//            Merge rules (the paper's): neither PC in a set -> both get a
//            fresh ssid from a wrapping allocator; exactly one in a set ->
//            the other joins it; both in sets -> both take min(ssid).
//
// Decay:     all valid bits (and the allocator) clear every 2^DECAY_W
//            cycles — cyclic clearing, the standard adaptivity mechanism
//            (cf. Alpha 21264 stWait table). A training that collides with
//            the decay cycle wins (fresh training survives the clear).
//
// Contract:  pure performance hint. Never checkpointed, never restored on
//            flush, architecturally invisible (ISS/lockstep unchanged).
//            Correctness never depends on table contents (docs/STORESET.md,
//            invariant INV-P1: predicted masks ⊆ conservative masks).
// ============================================================================

module ooo_stset #(
    parameter SSIT_AW = 6,    // log2(SSIT entries): 6 => 64 (5 => 32 escape)
    parameter DECAY_W = 16    // cyclic clear every 2^DECAY_W cycles
) (
    input  wire        clk,
    input  wire        reset,

    // R-stage lookups (combinational), slot0/slot1 in program order.
    // Inputs are word PCs: dr_pc*[7:2] (the low SSIT_AW bits are used).
    input  wire [5:0]  lk_pc0,
    output wire        lk_ssv0,      // pc0 belongs to a store set
    output wire [3:0]  lk_ssid0,
    input  wire [5:0]  lk_pc1,
    output wire        lk_ssv1,
    output wire [3:0]  lk_ssid1,

    // LFST view for the same slots. lf_*1 is already bypassed against a
    // same-cycle slot0 store write (a co-dispatched same-set older store),
    // so a slot1 load/store sees the true "last fetched store" of its set.
    output wire        lf_v0,
    output wire [2:0]  lf_pos0,
    output wire        lf_v1,
    output wire [2:0]  lf_pos1,

    // LFST writes: dispatching stores with a valid ssid (top gates with
    // ok*/dr_st*/lk_ssv*). Slot1 is younger: on an ssid collision its
    // write wins (last fetched store), enforced by write order below.
    input  wire        stw0_en,
    input  wire [3:0]  stw0_ssid,
    input  wire [2:0]  stw0_sqpos,
    input  wire        stw1_en,
    input  wire [3:0]  stw1_ssid,
    input  wire [2:0]  stw1_sqpos,

    // training: one-cycle pulse with the violated pair's word PCs [7:2]
    // (registered by the top — FF-sourced, off every timing path).
    input  wire        train_en,
    input  wire [5:0]  train_ldpc,
    input  wire [5:0]  train_stpc,
    output wire        train_busy    // lookups hijacked this cycle
);

    localparam SSIT_D = (1 << SSIT_AW);

    reg               ssit_v  [0:SSIT_D-1];
    reg  [3:0]        ssit_id [0:SSIT_D-1];
    reg               lfst_v  [0:15];
    reg  [2:0]        lfst_pos[0:15];
    reg  [3:0]        alloc_ctr;               // fresh-ssid allocator
    reg  [DECAY_W-1:0] decay_ctr;

    integer i;

    // ------------------------------------------------------------------
    // SSIT read ports. On a training cycle the two ports are borrowed for
    // the merge-rule reads (load entry on port0, store entry on port1);
    // train_busy makes the top ignore this cycle's predictions.
    // ------------------------------------------------------------------
    wire [SSIT_AW-1:0] ridx0 = train_en ? train_ldpc[SSIT_AW-1:0]
                                        : lk_pc0[SSIT_AW-1:0];
    wire [SSIT_AW-1:0] ridx1 = train_en ? train_stpc[SSIT_AW-1:0]
                                        : lk_pc1[SSIT_AW-1:0];
    wire       rv0  = ssit_v [ridx0];
    wire [3:0] rid0 = ssit_id[ridx0];
    wire       rv1  = ssit_v [ridx1];
    wire [3:0] rid1 = ssit_id[ridx1];

    assign lk_ssv0    = rv0 && !train_en;
    assign lk_ssid0   = rid0;
    assign lk_ssv1    = rv1 && !train_en;
    assign lk_ssid1   = rid1;
    assign train_busy = train_en;

    // ------------------------------------------------------------------
    // LFST read ports + slot1 same-cycle bypass: a slot0 store writing
    // slot1's set IS slot1's last-fetched older store this cycle.
    // ------------------------------------------------------------------
    assign lf_v0   = lfst_v  [rid0];
    assign lf_pos0 = lfst_pos[rid0];

    wire byp1 = stw0_en && (stw0_ssid == rid1);
    assign lf_v1   = byp1 ? 1'b1       : lfst_v  [rid1];
    assign lf_pos1 = byp1 ? stw0_sqpos : lfst_pos[rid1];

    // ------------------------------------------------------------------
    // state. Write order inside the block is the priority order (last
    // write wins): decay clear -> LFST slot0 -> LFST slot1 (younger wins
    // same-ssid collisions) -> training merge (survives a decay cycle).
    // ------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < SSIT_D; i = i + 1) begin
                ssit_v[i] <= 1'b0; ssit_id[i] <= 4'b0;
            end
            for (i = 0; i < 16; i = i + 1) begin
                lfst_v[i] <= 1'b0; lfst_pos[i] <= 3'b0;
            end
            alloc_ctr <= 4'b0;
            decay_ctr <= {DECAY_W{1'b0}};
        end else begin
            // cyclic decay: forget all trained sets every 2^DECAY_W cycles
            decay_ctr <= decay_ctr + {{(DECAY_W-1){1'b0}}, 1'b1};
            if (decay_ctr == {DECAY_W{1'b1}}) begin
                for (i = 0; i < SSIT_D; i = i + 1) ssit_v[i] <= 1'b0;
                for (i = 0; i < 16; i = i + 1)     lfst_v[i] <= 1'b0;
                alloc_ctr <= 4'b0;
            end

            // last-fetched-store updates from dispatching stores
            if (stw0_en) begin
                lfst_v  [stw0_ssid] <= 1'b1;
                lfst_pos[stw0_ssid] <= stw0_sqpos;
            end
            if (stw1_en) begin
                lfst_v  [stw1_ssid] <= 1'b1;
                lfst_pos[stw1_ssid] <= stw1_sqpos;
            end

            // training merge (rv*/rid* read via the hijacked ports above).
            // If both PCs alias to one SSIT index, both writes carry the
            // same value — last-write-wins is benign by construction.
            if (train_en) begin
                if (!rv0 && !rv1) begin
                    ssit_v [train_ldpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_ldpc[SSIT_AW-1:0]] <= alloc_ctr;
                    ssit_v [train_stpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_stpc[SSIT_AW-1:0]] <= alloc_ctr;
                    alloc_ctr <= alloc_ctr + 4'd1;
                end else if (rv0 && !rv1) begin
                    ssit_v [train_stpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_stpc[SSIT_AW-1:0]] <= rid0;
                end else if (!rv0 && rv1) begin
                    ssit_v [train_ldpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_ldpc[SSIT_AW-1:0]] <= rid1;
                end else begin
                    // both in sets: both take min(ssid) — the paper's
                    // declared-winner rule (other members migrate lazily,
                    // one violation each; no full-table remap)
                    ssit_v [train_ldpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_ldpc[SSIT_AW-1:0]] <=
                        (rid0 < rid1) ? rid0 : rid1;
                    ssit_v [train_stpc[SSIT_AW-1:0]] <= 1'b1;
                    ssit_id[train_stpc[SSIT_AW-1:0]] <=
                        (rid0 < rid1) ? rid0 : rid1;
                end
            end
        end
    end

`ifdef VERILATOR
    // two same-cycle stores can never share an SQ slot (they allocate at
    // tail and tail+1) — if this fires the top's stw wiring is wrong
    always @(posedge clk) if (!reset) begin
        if (stw0_en && stw1_en && (stw0_sqpos == stw1_sqpos))
            $fatal(1, "ooo_stset: two same-cycle stores share an SQ slot");
    end
`endif

endmodule
