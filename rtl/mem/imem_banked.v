// ============================================================================
// imem_banked — even/odd-banked M9K instruction ROM pair (D022)
//
// Purpose:    Program store for the 2-wide OoO frontend, built from two
//             single-port block-RAM banks so BOTH words of a fetch pair map
//             into MAX 10 M9K (the 4 KB logic-ROM imem burned the ~4-5k LEs
//             that pushed the board top past the 10M50's capacity — B006).
// Interfaces: pc (slot-0 byte address) -> registered instr0/instr1, the
//             words at pc and pc+4, valid the cycle AFTER a capture edge.
//             rd_en is the capture enable; !rd_en freezes both read
//             registers (the positive form of imem.v's B012 `hold`: pc has
//             already advanced past a held group, so freezing the PC alone
//             would lose the stalled pair).
// Banking:    word i lives in bank (i & 1) at bank address (i >> 1) — the
//             same convention scripts/hex2mif.py states; keep the two in
//             sync. pc and pc+4 always have opposite word parity, so each
//             single-port bank serves exactly one slot every cycle, for
//             aligned and unaligned pairs alike:
//               w0 = pc word index; even-bank addr = (w0>>1) + w0[0]
//                                   odd-bank  addr = (w0>>1)
//             (w0 even: even bank holds w0, odd bank holds w0+1, both at
//              w0>>1. w0 odd: odd bank holds w0 at w0>>1, even bank holds
//              w0+1 at (w0>>1)+1.) The output crossbar un-swaps the pair
//             using pc's parity REGISTERED WITH THE READ (sel_q): the pc on
//             the address bus moves on, the captured pair must not.
// Contents:   Simulation loads a flat hex ($readmemh, +imem=<file> override)
//             and splits it into the banks; unused words are NOP-padded.
//             For synthesis the banks carry ram_init_file attributes naming
//             synth/imem_even.mif / imem_odd.mif (`make mif`) — the explicit
//             init file MAX 10 needs, since Quartus 20.1 refuses to MIF-init
//             an auto-inferred initialized ROM (B006, "MIF not supported for
//             the selected family"). No initial block exists on the banks
//             outside simulation: the .mif files are the sole initializer.
// Assumes:    pc word-aligned (pc[1:0] ignored); upper address bits alias;
//             running past the program is harmless (NOP padding, both in
//             sim and in the generated MIFs).
// ============================================================================
module imem_banked #(
`ifdef SIM_BIG_MEM
    parameter DEPTH_WORDS = 65536,                     // 256 KB (benchmarks)
`else
    parameter DEPTH_WORDS = 1024,                      // 4 KB of program
`endif
    // Simulation fallback program when no +imem override is given (path
    // relative to the repo root, where the Verilator harness runs).
    parameter MEM_FILE    = "sw/demo/led_demo.hex"
)(
    input  wire        clk,
    input  wire        rd_en,    // capture enable; low = hold current pair
    input  wire [31:0] pc,       // slot-0 byte address (slot 1 is pc+4)
    output wire [31:0] instr0,   // registered word at pc
    output wire [31:0] instr1    // registered word at pc+4
);

    localparam AW = $clog2(DEPTH_WORDS);   // word-address width
    localparam BW = AW - 1;                // per-bank address width

    // NOTE: keep the word "synthesis" out of ordinary comments in this file —
    // Quartus parses "synthesis <x>" inside comments as a pragma. The two
    // attributes below exploit exactly that; their .mif paths resolve
    // relative to the Quartus project dir (synth/). Verilator sees only a
    // plain comment.
    reg [31:0] bank_even [0:DEPTH_WORDS/2-1] /* synthesis ram_init_file = "imem_even.mif" */;
    reg [31:0] bank_odd  [0:DEPTH_WORDS/2-1] /* synthesis ram_init_file = "imem_odd.mif" */;

    // Bank addressing (derivation in the header). The BW-bit add wraps at
    // the top of memory — same upper-bit aliasing as imem.v.
    wire [AW-1:0] w0 = pc[AW+1:2];
    wire [BW-1:0] ea = w0[AW-1:1] + {{(BW-1){1'b0}}, w0[0]};
    wire [BW-1:0] oa = w0[AW-1:1];

    // Registered reads (the M9K read-register pattern, D016/B006) plus the
    // captured parity. All three share rd_en so a held pair stays coherent.
    reg [31:0] even_q, odd_q;
    reg        sel_q;
    always @(posedge clk) if (rd_en) begin
        even_q <= bank_even[ea];
        odd_q  <= bank_odd [oa];
        sel_q  <= w0[0];
    end

    // Output crossbar on the REGISTERED parity — a combinational select from
    // the current pc would mis-pair whenever pc has advanced past the hold.
    assign instr0 = sel_q ? odd_q  : even_q;
    assign instr1 = sel_q ? even_q : odd_q;

`ifdef VERILATOR
    // Simulation init: NOP-pad a flat staging image (running past the
    // program's end is harmless, not X-propagation), load the program
    // (+imem=<hexfile> override, as the harness always passes), then split
    // even/odd words into the banks. `flat` survives as a shadow copy for
    // the INV-F1 self-check below.
    integer i;
    reg [8*256:1] hexfile;
    reg [31:0] flat [0:DEPTH_WORDS-1];
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            flat[i] = 32'h00000013;  // addi x0, x0, 0
        if ($value$plusargs("imem=%s", hexfile))
            $readmemh(hexfile, flat);
        else
            $readmemh(MEM_FILE, flat);
        for (i = 0; i < DEPTH_WORDS; i = i + 2) begin
            bank_even[i/2] = flat[i];
            bank_odd [i/2] = flat[i+1];
        end
    end

    // INV-F1: after every capture, the crossbarred outputs equal the flat
    // image at the captured pc / pc+4 — checks the split, both banks'
    // address math, and the crossbar polarity on every fetch of every test.
    reg [31:0] chk_pc_q;
    reg        chk_cap_q;
    wire [AW-1:0] chk_w0 = chk_pc_q[AW+1:2];
    wire [AW-1:0] chk_w1 = chk_w0 + {{(AW-1){1'b0}}, 1'b1};  // wraps like HW
    initial begin chk_pc_q = 32'b0; chk_cap_q = 1'b0; end
    always @(posedge clk) begin
        if (chk_cap_q) begin
            if (instr0 !== flat[chk_w0])
                $fatal(1, "imem_banked: instr0 mismatch at pc=%h", chk_pc_q);
            if (instr1 !== flat[chk_w1])
                $fatal(1, "imem_banked: instr1 mismatch at pc=%h", chk_pc_q);
        end
        if (rd_en) begin
            chk_pc_q  <= pc;
            chk_cap_q <= 1'b1;
        end
    end
`endif

endmodule
