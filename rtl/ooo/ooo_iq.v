// ============================================================================
// ooo_iq — unified 16-entry issue queue (decision D013)
//
// Purpose:    Holds dispatched uops until their operands are ready, then
//             selects up to 3 per cycle, oldest-first, one per port:
//               port0: branches/JALR, falls back to plain ALU ops
//               port1: ALU ops + CSR ops (csr_file is wired to port1)
//               port2: loads/stores
// Scheduling contracts (docs/OOO.md):
//   * ALU/branch/store grants broadcast their dest tag AT SELECT — a
//     dependent can be selected the very next cycle (zero-bubble chains
//     via the EX bypass network). Loads broadcast at WRITEBACK instead
//     (external wkl bus) because a load may replay.
//   * Entries deallocate at select, except loads which set `issued` and
//     deallocate at WB-success (ldone) or re-arm on replay (rep).
//   * A load is eligible only when its older-unknown-store mask is 0.
//     The mask is snapshotted at dispatch and ANDed each cycle with the
//     SQ's current unknown mask — bits only ever clear, and a reused SQ
//     slot can never re-set a bit (a store reusing a slot is younger
//     than this load by construction).
//   * Age = 6-bit ROB-tag distance from the ROB head tag.
// ============================================================================
`include "ooo_uop.vh"

module ooo_iq (
    input  wire              clk,
    input  wire              reset,

    // ROB head tag for age comparison
    input  wire [5:0]        head_tag,

    // dispatch (slot0 older than slot1)
    input  wire              disp0_en,
    input  wire [`UOPW-1:0]  disp0_uop,
    input  wire              disp0_r1,     // ps1 ready at dispatch
    input  wire              disp0_r2,
    input  wire [7:0]        disp0_mask,   // loads: older-unknown-store mask
    input  wire              disp1_en,
    input  wire [`UOPW-1:0]  disp1_uop,
    input  wire              disp1_r1,
    input  wire              disp1_r2,
    input  wire [7:0]        disp1_mask,
    output wire              free_ge1,
    output wire              free_ge2,

    // SQ current unknown-address mask (valid & ~addr_known)
    input  wire [7:0]        sq_unknown,

    // load writeback tag broadcast (external wakeup)
    input  wire              wkl_en,
    input  wire [5:0]        wkl_tag,

    // load replay / load done (by ROB tag)
    input  wire              rep_en,
    input  wire [5:0]        rep_tag,
    input  wire              ldone_en,
    input  wire [5:0]        ldone_tag,

    // squash: kill entries strictly younger than flush_tag
    input  wire              flush_en,
    input  wire [5:0]        flush_tag,

    // selects
    output reg               sel0_v,
    output reg  [`UOPW-1:0]  sel0_uop,
    output reg               sel1_v,
    output reg  [`UOPW-1:0]  sel1_uop,
    output reg               sel2_v,
    output reg  [`UOPW-1:0]  sel2_uop
);

`include "ooo_pkg.vh"

    reg              v      [0:IQD-1];
    reg              issued [0:IQD-1];
    reg              r1     [0:IQD-1];
    reg              r2     [0:IQD-1];
    reg  [7:0]       mask   [0:IQD-1];
    reg  [`UOPW-1:0] u      [0:IQD-1];

    integer i;

    // ------------------------------------------------------------------
    // eligibility
    // ------------------------------------------------------------------
    wire [IQD-1:0] elig_br, elig_alu, elig_mem;
    wire [5:0]     relage [0:IQD-1];

    genvar g;
    generate
        for (g = 0; g < IQD; g = g + 1) begin : ELIG
            wire ready = v[g] && !issued[g] && r1[g] && r2[g];
            wire is_ctrl = u[g][`U_ISBR] | u[g][`U_ISJALR];
            wire is_mem  = u[g][`U_ISLOAD] | u[g][`U_ISSTORE];
            wire ld_ok   = !u[g][`U_ISLOAD] || (mask[g] == 8'b0);
            assign elig_br[g]  = ready && is_ctrl;
            assign elig_alu[g] = ready && !is_ctrl && !is_mem;
            assign elig_mem[g] = ready && is_mem && ld_ok;
            assign relage[g]   = u[g][`U_TAG] - head_tag;
        end
    endgenerate

    // oldest-first pick over an eligibility vector (serial min chain —
    // fine at 16 entries; timing work is a later, measured stage)
    function [4:0] pick;  // returns {found, idx[3:0]}
        input [IQD-1:0] e;
        reg  [5:0] best;
        reg  [3:0] bi;
        reg        f;
        integer    k;
        begin
            best = 6'd63; bi = 4'd0; f = 1'b0;
            for (k = 0; k < IQD; k = k + 1) begin
                if (e[k] && (!f || (relage[k] < best))) begin
                    f = 1'b1; best = relage[k]; bi = k[3:0];
                end
            end
            pick = {f, bi};
        end
    endfunction

    // port0: prefer control ops; otherwise oldest plain ALU op.
    // CSR ops must issue on port1 (csr_file lives there): exclude them
    // from the port0 fallback set
    wire [4:0] p_br = pick(elig_br);
    wire [IQD-1:0] elig_alu_noncsr;
    generate
        for (g = 0; g < IQD; g = g + 1) begin : NC
            assign elig_alu_noncsr[g] = elig_alu[g] && !u[g][`U_ISCSR];
        end
    endgenerate
    wire [4:0] p_alu0nc = pick(elig_alu_noncsr);
    wire       gr0_v    = p_br[4] | p_alu0nc[4];
    wire [3:0] gr0_i    = p_br[4] ? p_br[3:0] : p_alu0nc[3:0];

    // port1: oldest ALU/CSR excluding port0's grant
    wire [IQD-1:0] elig_alu_m1;
    generate
        for (g = 0; g < IQD; g = g + 1) begin : M1
            assign elig_alu_m1[g] = elig_alu[g]
                                    && !(gr0_v && (gr0_i == g[3:0]));
        end
    endgenerate
    wire [4:0] p_alu1 = pick(elig_alu_m1);

    // port2: oldest memory op
    wire [4:0] p_mem = pick(elig_mem);

    // ------------------------------------------------------------------
    // select-time wakeup tags (internal: port0/port1 grants; stores on
    // port2 have wr=0 so they never broadcast; loads use the WB bus)
    // ------------------------------------------------------------------
    wire        wk0_en  = gr0_v && u[gr0_i][`U_WR];
    wire [5:0]  wk0_tag = u[gr0_i][`U_PD];
    wire        wk1_en  = p_alu1[4] && u[p_alu1[3:0]][`U_WR];
    wire [5:0]  wk1_tag = u[p_alu1[3:0]][`U_PD];

    function wakes;
        input [5:0] tag;
        begin
            wakes = (wk0_en && wk0_tag == tag)
                 || (wk1_en && wk1_tag == tag)
                 || (wkl_en && wkl_tag == tag);
        end
    endfunction

    // ------------------------------------------------------------------
    // free-slot allocation for dispatch
    // ------------------------------------------------------------------
    reg [3:0] free0, free1;
    reg       f0v, f1v;
    always @(*) begin
        f0v = 1'b0; f1v = 1'b0; free0 = 4'd0; free1 = 4'd0;
        for (i = IQD - 1; i >= 0; i = i - 1)
            if (!v[i]) begin
                free1 = free0; f1v = f0v;
                free0 = i[3:0]; f0v = 1'b1;
            end
    end
    assign free_ge1 = f0v;
    assign free_ge2 = f0v && f1v;

    // ------------------------------------------------------------------
    // select outputs (registered grants would add a cycle; combinational
    // outputs latch into the RF stage registers in the top)
    // ------------------------------------------------------------------
    always @(*) begin
        sel0_v   = gr0_v;
        sel0_uop = u[gr0_i];
        sel1_v   = p_alu1[4];
        sel1_uop = u[p_alu1[3:0]];
        sel2_v   = p_mem[4];
        sel2_uop = u[p_mem[3:0]];
    end

    // ------------------------------------------------------------------
    // state update
    // ------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < IQD; i = i + 1) begin
                v[i] <= 1'b0; issued[i] <= 1'b0;
                r1[i] <= 1'b0; r2[i] <= 1'b0;
                mask[i] <= 8'b0; u[i] <= {`UOPW{1'b0}};
            end
        end else begin
            // wakeups + mask decay on resident entries
            for (i = 0; i < IQD; i = i + 1) begin
                if (v[i]) begin
                    if (wakes(u[i][`U_PS1])) r1[i] <= 1'b1;
                    if (wakes(u[i][`U_PS2])) r2[i] <= 1'b1;
                    mask[i] <= mask[i] & sq_unknown;
                end
            end

            // deallocation at select (non-loads); loads mark issued
            if (gr0_v)     v[gr0_i]        <= 1'b0;
            if (p_alu1[4]) v[p_alu1[3:0]]  <= 1'b0;
            if (p_mem[4]) begin
                if (u[p_mem[3:0]][`U_ISLOAD]) issued[p_mem[3:0]] <= 1'b1;
                else                          v[p_mem[3:0]]      <= 1'b0;
            end

            // load replay / completion (by ROB tag)
            for (i = 0; i < IQD; i = i + 1) begin
                if (v[i] && u[i][`U_ISLOAD] && issued[i]) begin
                    if (rep_en   && u[i][`U_TAG] == rep_tag)
                        issued[i] <= 1'b0;
                    if (ldone_en && u[i][`U_TAG] == ldone_tag)
                        v[i] <= 1'b0;
                end
            end

            // dispatch (after dealloc so a freed slot is reusable next
            // cycle only — free list computed from registered v ensures
            // no same-cycle reuse of a granted slot)
            if (disp0_en && f0v) begin
                v[free0]      <= 1'b1;
                issued[free0] <= 1'b0;
                u[free0]      <= disp0_uop;
                r1[free0]     <= disp0_r1 || wakes(disp0_uop[`U_PS1]);
                r2[free0]     <= disp0_r2 || wakes(disp0_uop[`U_PS2]);
                mask[free0]   <= disp0_mask;
            end
            if (disp1_en && f1v) begin
                v[free1]      <= 1'b1;
                issued[free1] <= 1'b0;
                u[free1]      <= disp1_uop;
                r1[free1]     <= disp1_r1 || wakes(disp1_uop[`U_PS1]);
                r2[free1]     <= disp1_r2 || wakes(disp1_uop[`U_PS2]);
                mask[free1]   <= disp1_mask;
            end

            // squash LAST: overrides dispatch/wakeup of dying entries
            if (flush_en) begin
                for (i = 0; i < IQD; i = i + 1)
                    if (v[i] && ((u[i][`U_TAG] - head_tag)
                                 > (flush_tag - head_tag)))
                        v[i] <= 1'b0;
                // dispatching entries are younger than any resolving
                // branch by construction; kill them too
                if (disp0_en && f0v) v[free0] <= 1'b0;
                if (disp1_en && f1v) v[free1] <= 1'b0;
            end
        end
    end

endmodule
