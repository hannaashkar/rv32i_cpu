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
    output reg         vio_en,
    output reg  [5:0]  vio_tag,

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

    // ------------------------------------------------------------------
    // violation CAM (combinational): oldest younger executed overlapping load
    // ------------------------------------------------------------------
    reg        m_found;
    reg [5:0]  m_age;      // (tag - head) of the current best (oldest) match
    reg [5:0]  m_tag;
    always @(*) begin
        m_found = 1'b0; m_age = 6'd63; m_tag = 6'd0;
        if (st_fill_en) begin
            for (i = 0; i < LQD; i = i + 1) begin
                // valid, executed, YOUNGER than the store, same word,
                // byte-mask overlap
                if (v[i] && executed[i]
                    && ((tag[i] - head_tag) > (st_tag - head_tag))
                    && (waddr[i] == st_waddr)
                    && ((bmask[i] & st_bytemask) != 4'b0)) begin
                    // keep the OLDEST such younger load (smallest age)
                    if (!m_found || ((tag[i] - head_tag) < m_age)) begin
                        m_found = 1'b1;
                        m_age   = tag[i] - head_tag;
                        m_tag   = tag[i];
                    end
                end
            end
        end
        vio_en  = m_found;
        vio_tag = m_tag;
    end

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
            if (alloc1_en && f1v) begin
                v[free1]        <= 1'b1;
                executed[free1] <= 1'b0;
                tag[free1]      <= alloc1_tag;
            end

            // squash LAST (overrides alloc of dying entries)
            if (flush_all) begin
                for (i = 0; i < LQD; i = i + 1) v[i] <= 1'b0;
            end else if (flush_en) begin
                for (i = 0; i < LQD; i = i + 1)
                    if (v[i] && ((tag[i] - head_tag) > (flush_tag - head_tag)))
                        v[i] <= 1'b0;
                if (alloc0_en && f0v) v[free0] <= 1'b0;
                if (alloc1_en && f1v) v[free1] <= 1'b0;
            end
        end
    end

endmodule
