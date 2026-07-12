// ============================================================================
// ooo_prf — merged physical register file, 6R / 3W (D013), M9K-backed (D025)
//
// Purpose:    Holds ALL register values (committed and speculative) in one
//             file, R10K style. p0 is architecturally zero: never written to
//             observably (reads of p0 return 0). This is the D025 rewrite:
//             the storage moved from an async-read fabric register array
//             (~10.9k LCs, the audit's second LE pig) into block RAM, using
//             the LaForest/Steffan LVT multi-ported-RAM construction. Same
//             "fold the read address into the RAM's own address register"
//             trick as dmem (D016), imem (D022) and gshare (D024) — so it is
//             IPC-neutral and lockstep-verifiable.  docs/PRF_SHRINK.md is the
//             options sheet; DECISIONS.md D025 is the binding record.
//
// ----------------------------------------------------------------------------
// The fold (why a synchronous RAM read costs no cycle)
//
//   SEL cycle              RF cycle                 EX cycle
//   s*_tag  ----edge----> (RAM addr reg) ---read--> r*  ---edge---> ex_a/ex_b
//           (this is also  rtag[]                        (captured into the
//            rf_u's tag)                                   EX operand latch)
//
//   The read tag consumed in RF is rf_u[i][PS], whose next value is the
//   SEL-stage sel_uop[i][PS]. We take that PRE-flop tag on s*_tag, register
//   it into the RAM's address port (and into rtag[] for the bypass compare),
//   and the synchronous read data lands during the RF cycle — bit-aligned
//   with the old async read. The RF stage never stalls (bubbles ride the
//   valid bits, data regs are clocked every edge), so NO clock-enable/hold
//   is needed on the RAM address register (simpler than imem's B012 hold).
//
// ----------------------------------------------------------------------------
// Multi-porting block RAM: LVT (Live Value Table)  [LaForest & Steffan '10]
//
//   * Reads -> replication: 6 read copies of the storage; every write is
//     broadcast to all copies for its bank.
//   * Writes -> banking: each of the 3 write ports owns a bank; the LVT
//     (64 x 2 bits, a small register array) records which write bank last
//     wrote each physical register. A read looks up the LVT to pick the
//     live bank.
//   Grid = 6 read copies x 3 write banks = 18 M9K blocks (64x32 each).
//
// ----------------------------------------------------------------------------
// Bit-exact write-first (the PRF is NOT a hint like the PHT was)
//
//   An M9K returns OLD data for a write that lands on the read address at
//   the SEL->RF edge, so two external bypass levels rebuild the async file's
//   write-first semantics exactly:
//     - direct : a write ACTIVE THIS (RF) cycle whose tag == rtag  (this is
//                the original rd_bypass, unchanged);
//     - shadow : a write from the PREVIOUS cycle (registered copy of the
//                write ports) — patches the single edge the M9K's OLD_DATA
//                drops (the value is already committed in regs by then, but
//                the M9K read latched its address on that same edge);
//     - else   : the bank value selected by the folded LVT read.
//   Physical tags are single-assignment while allocated, so at most one of
//   these matches (INV-P1 arms it) — the priority order is a formality.
//
//   Correctness proof (async reference = the old rd_bypass at the RF cycle):
//   let a producer's WB cycle be W and a reader's RF cycle be C. The reader
//   needs the produced value for all C >= W (earlier readers take the value
//   off the EX bypass net, not the PRF).  C==W -> direct; C==W+1 -> shadow;
//   C>=W+2 -> bank (the LVT owner is >=1 cycle old, so the folded LVT read
//   already reflects it). All three windows are covered with no overlap.
//
// Ports:      clk/reset; six SEL-stage source tags (s0a..s2b); six read data
//             outputs; three write ports (en/tag/data).
// ============================================================================
module ooo_prf (
    input  wire        clk,
    input  wire        reset,

    // Read address = SEL-stage (pre-flop) source tags. Registered inside
    // (into the RAM address regs + rtag[]) so the read data is valid in the
    // RF cycle, exactly where the old async outputs were.
    input  wire [5:0]  s0a_tag, s0b_tag,   // port0 rs1/rs2
    input  wire [5:0]  s1a_tag, s1b_tag,   // port1 rs1/rs2
    input  wire [5:0]  s2a_tag, s2b_tag,   // port2 rs1/rs2
    output wire [31:0] r0a, r0b, r1a, r1b, r2a, r2b,

    input  wire        w0_en, w1_en, w2_en,
    input  wire [5:0]  w0_tag, w1_tag, w2_tag,
    input  wire [31:0] w0_data, w1_data, w2_data
);

    parameter INIT_FILE = "prf_zero.mif";   // synthesis power-up = all zero

    // ------------------------------------------------------------------
    // Flatten I/O into arrays: 6 read ports (0..5), 3 write banks (0..2).
    // ------------------------------------------------------------------
    wire [5:0]  stag [0:5];
    assign stag[0] = s0a_tag; assign stag[1] = s0b_tag;
    assign stag[2] = s1a_tag; assign stag[3] = s1b_tag;
    assign stag[4] = s2a_tag; assign stag[5] = s2b_tag;

    wire        wen  [0:2];
    wire [5:0]  wtag [0:2];
    wire [31:0] wdat [0:2];
    assign wen[0] = w0_en;  assign wtag[0] = w0_tag;  assign wdat[0] = w0_data;
    assign wen[1] = w1_en;  assign wtag[1] = w1_tag;  assign wdat[1] = w1_data;
    assign wen[2] = w2_en;  assign wtag[2] = w2_tag;  assign wdat[2] = w2_data;

    integer k;

    // ------------------------------------------------------------------
    // rf-stage tag (the fold's compare key) — reset for determinism.
    // ------------------------------------------------------------------
    reg [5:0] rtag [0:5];
    always @(posedge clk or posedge reset)
        if (reset) for (k = 0; k < 6; k = k + 1) rtag[k] <= 6'd0;
        else       for (k = 0; k < 6; k = k + 1) rtag[k] <= stag[k];

    // ------------------------------------------------------------------
    // LVT: owner (write bank id) of each physical register.  Not reset —
    // it tracks the data banks (which cannot be cleared, like the old
    // async 'regs'); it powers up 0 (cold start reads bank 0 = 0). The
    // folded per-port select IS reset (control, must be deterministic).
    // ------------------------------------------------------------------
    reg [1:0] lvt [0:63];
    reg [1:0] lvt_sel_rf [0:5];

    always @(posedge clk) begin
        // owner update — single-assignment => at most one hits a tag
        if (wen[0]) lvt[wtag[0]] <= 2'd0;
        if (wen[1]) lvt[wtag[1]] <= 2'd1;
        if (wen[2]) lvt[wtag[2]] <= 2'd2;
    end

    always @(posedge clk or posedge reset)
        if (reset) for (k = 0; k < 6; k = k + 1) lvt_sel_rf[k] <= 2'd0;
        else       for (k = 0; k < 6; k = k + 1) lvt_sel_rf[k] <= lvt[stag[k]];

    // ------------------------------------------------------------------
    // Shadow: 1-cycle-older copy of the write ports. Only the enable is
    // reset (gates the bypass); tag/data are don't-care while en=0, and
    // left un-reset to save the wide async-reset flops (audit lever).
    // ------------------------------------------------------------------
    reg        wen_q  [0:2];
    reg [5:0]  wtag_q [0:2];
    reg [31:0] wdat_q [0:2];
    always @(posedge clk or posedge reset)
        if (reset) begin
            for (k = 0; k < 3; k = k + 1) wen_q[k] <= 1'b0;
        end else begin
            for (k = 0; k < 3; k = k + 1) begin
                wen_q[k]  <= wen[k];
                wtag_q[k] <= wtag[k];
                wdat_q[k] <= wdat[k];
            end
        end

    // ------------------------------------------------------------------
    // The 18 banked block RAMs. bank_q[r*3 + w] = read copy r of bank w,
    // registered read of addr stag[r] (OLD_DATA read-during-write).
    // ------------------------------------------------------------------
    wire [31:0] bank_q [0:17];

    genvar r, w;
`ifdef VERILATOR
    // Behavioral twin: 3 write-bank memories, read 6 times each. The
    // registered read with a same-edge write returns OLD data (nonblocking
    // RHS reads pre-write memory) — matching altsyncram OLD_DATA below.
    reg [31:0] wmem0 [0:63];
    reg [31:0] wmem1 [0:63];
    reg [31:0] wmem2 [0:63];
    reg [31:0] bank_q_r [0:17];
    integer bi;
    initial begin
        for (bi = 0; bi < 64; bi = bi + 1) begin
            wmem0[bi] = 32'b0; wmem1[bi] = 32'b0; wmem2[bi] = 32'b0;
        end
        for (bi = 0; bi < 18; bi = bi + 1) bank_q_r[bi] = 32'b0;
    end
    always @(posedge clk) begin
        if (wen[0]) wmem0[wtag[0]] <= wdat[0];
        if (wen[1]) wmem1[wtag[1]] <= wdat[1];
        if (wen[2]) wmem2[wtag[2]] <= wdat[2];
        for (bi = 0; bi < 6; bi = bi + 1) begin
            bank_q_r[bi*3 + 0] <= wmem0[stag[bi]];
            bank_q_r[bi*3 + 1] <= wmem1[stag[bi]];
            bank_q_r[bi*3 + 2] <= wmem2[stag[bi]];
        end
    end
    generate for (r = 0; r < 18; r = r + 1) begin : g_bq
        assign bank_q[r] = bank_q_r[r];
    end endgenerate
`else
    // Synthesis: one explicit altsyncram per (read copy, write bank),
    // simple-dual-port (port A = full-word write, port B = registered
    // address read), MIF-init to 0. Same recipe as dmem (B006/D022):
    // explicit instance + M9K + ERAM config mode is required on MAX 10.
    generate for (r = 0; r < 6; r = r + 1) begin : g_rc
      for (w = 0; w < 3; w = w + 1) begin : g_bk
        altsyncram #(
            .operation_mode("DUAL_PORT"),
            .width_a(32),
            .widthad_a(6),
            .numwords_a(64),
            .width_b(32),
            .widthad_b(6),
            .numwords_b(64),
            .address_reg_b("CLOCK0"),
            .outdata_reg_b("UNREGISTERED"),
            .init_file(INIT_FILE),
            .intended_device_family("MAX 10"),
            .ram_block_type("M9K"),
            .lpm_type("altsyncram"),
            .read_during_write_mode_mixed_ports("OLD_DATA")
        ) U_BANK (
            .clock0(clk),
            .wren_a(wen[w]),
            .address_a(wtag[w]),
            .data_a(wdat[w]),
            .address_b(stag[r]),
            .q_b(bank_q[r*3 + w])
        );
      end
    end endgenerate
`endif

    // ------------------------------------------------------------------
    // Read output: LVT-selected bank background, overridden by the direct
    // (this cycle) and shadow (last cycle) write-first bypass, p0 = 0.
    // ------------------------------------------------------------------
    wire [31:0] bg [0:5];
    wire [31:0] rd [0:5];
    generate for (r = 0; r < 6; r = r + 1) begin : g_rd
        assign bg[r] = (lvt_sel_rf[r] == 2'd0) ? bank_q[r*3 + 0]
                     : (lvt_sel_rf[r] == 2'd1) ? bank_q[r*3 + 1]
                     :                           bank_q[r*3 + 2];

        assign rd[r] =
            (rtag[r] == 6'd0)                       ? 32'b0
          : (wen[0]   && wtag[0]   == rtag[r])      ? wdat[0]
          : (wen[1]   && wtag[1]   == rtag[r])      ? wdat[1]
          : (wen[2]   && wtag[2]   == rtag[r])      ? wdat[2]
          : (wen_q[0] && wtag_q[0] == rtag[r])      ? wdat_q[0]
          : (wen_q[1] && wtag_q[1] == rtag[r])      ? wdat_q[1]
          : (wen_q[2] && wtag_q[2] == rtag[r])      ? wdat_q[2]
          :                                          bg[r];
    end endgenerate

    assign r0a = rd[0]; assign r0b = rd[1];
    assign r1a = rd[2]; assign r1b = rd[3];
    assign r2a = rd[4]; assign r2b = rd[5];

    // ------------------------------------------------------------------
    // Invariants (Verilator-only; Quartus never defines VERILATOR).
    //   INV-P1: single-assignment — no two active write ports share a tag
    //           (the LVT owner and the direct-bypass priority both rely on
    //           it; a violation would silently pick a bank).
    // ------------------------------------------------------------------
`ifdef VERILATOR
    always @(posedge clk) if (!reset) begin
        if (wen[0] && wen[1] && wtag[0] == wtag[1])
            $fatal(1, "ooo_prf INV-P1: w0/w1 share tag %0d", wtag[0]);
        if (wen[0] && wen[2] && wtag[0] == wtag[2])
            $fatal(1, "ooo_prf INV-P1: w0/w2 share tag %0d", wtag[0]);
        if (wen[1] && wen[2] && wtag[1] == wtag[2])
            $fatal(1, "ooo_prf INV-P1: w1/w2 share tag %0d", wtag[1]);
    end
`endif

endmodule
