// ============================================================================
// imem — instruction memory (word-addressed)
//
// Purpose:    Holds the program the core executes. Contents are loaded from
//             a hex file ($readmemh format: one 32-bit word per line,
//             little-endian instruction words, '//' comments allowed).
// Interfaces: pc (byte address from IF) -> instruction. A second read port
//             (pc2/instruction2) feeds the 2-wide OoO frontend (D013).
// Read timing is selected by SYNC_READ (BUGLOG B006, decision D016):
//   SYNC_READ=0 — combinational read (original behavior); synthesizes to
//     logic cells. Still used by the OoO core until its own memory rework.
//   SYNC_READ=1 — registered read: mem[idx] is captured in an output
//     register, the pattern Quartus needs to infer a MAX10 M9K block. The
//     instruction is then valid the cycle AFTER pc is presented — i.e. in
//     the Decode cycle. The in-order core folds its former IF/ID
//     instruction latch into this register, so fetch stays IPC-neutral:
//     wrong-path / startup slots are squashed to a NOP in cpu_pipeline via
//     the pipeline valid bit instead of inside IF/ID.
//
// Program loading:
//   * Synthesis: MEM_FILE, resolved relative to the Quartus project dir
//     (synth/), defaults to the original LED demo program.
//   * Simulation: pass +imem=<hexfile> at runtime; the Verilator harness
//     always does this, so programs swap without recompiling the model.
// ============================================================================
module imem #(
`ifdef SIM_BIG_MEM
    parameter DEPTH_WORDS = 65536,                     // 256 KB (benchmarks)
`else
    parameter DEPTH_WORDS = 1024,                      // 4 KB of program
`endif
    // Default program used by Quartus builds (path relative to synth/).
    // NOTE: keep the word "synthesis" out of trailing comments here —
    // Quartus parses "synthesis <x>" inside comments as a pragma.
    parameter MEM_FILE    = "../sw/demo/led_demo.hex",
    parameter SYNC_READ   = 0                          // 1 = registered read
)(
    input  wire        clk,          // used only when SYNC_READ=1
    input  wire        hold,         // SYNC_READ=1: freeze the fetch register
    input  wire [31:0] pc,           // byte address from Fetch stage
    output reg  [31:0] instruction,  // fetched instruction
    // Second fetch port for the 2-wide OoO frontend (D013). The in-order
    // top ties pc2 to 0 and leaves instruction2 unconnected (pruned).
    input  wire [31:0] pc2,
    output reg  [31:0] instruction2
);

    // NOTE (B006): with the registered read below this program store is now
    // structurally M9K-ready, but Quartus 20.1 leaves it as logic ("MIF not
    // supported for the selected family") when an initialized ROM is
    // auto-inferred on MAX 10. Mapping it into M9K needs an explicit init
    // file (ram_init_file = program.hex/.mif) — deferred to the on-board
    // large-program stage, where a real program (not the tiny LED demo)
    // makes the block-RAM ROM worthwhile. dmem (the ~8k-FF store) already
    // infers block RAM. The synchronous read here is what matters for
    // timing (B005): it breaks the async instruction-fetch critical path.
    reg [31:0] mem [0:DEPTH_WORDS-1];

`ifdef VERILATOR
    integer i;
    reg [8*256:1] hexfile;           // +imem=<path> runtime override
    initial begin
        // Simulation: NOP-pad the whole array (so running past the program's
        // end is harmless, not X-propagation), then load the program.
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'h00000013;   // addi x0, x0, 0
        if ($value$plusargs("imem=%s", hexfile))
            $readmemh(hexfile, mem);
        else
            $readmemh(MEM_FILE, mem);
    end
`else
    // Synthesis: initialize the program ROM straight from the hex file so
    // Quartus can build the M9K init (MIF). A procedural NOP-fill loop mixed
    // with $readmemh blocks MIF generation on MAX 10 (the RAM is left
    // uninferred, B006), so the file is the sole initializer here; any
    // unwritten words default to 0.
    initial $readmemh(MEM_FILE, mem);
`endif

    // Word-aligned access: pc[1:0] ignored, upper bits alias.
    wire [$clog2(DEPTH_WORDS)-1:0] idx  = pc [$clog2(DEPTH_WORDS)+1:2];
    wire [$clog2(DEPTH_WORDS)-1:0] idx2 = pc2[$clog2(DEPTH_WORDS)+1:2];

    generate if (SYNC_READ != 0) begin : g_sync_fetch
        // Registered read (B006/D016) — maps to the M9K read register — with
        // a hold enable. When Decode is stalled (load-use, or the NPU
        // interlock) the fetch register must FREEZE the current instruction:
        // imem's read address (pc) has already advanced to the next fetch,
        // so freezing the PC alone is not enough — the held instruction was
        // fetched from the previous PC. hold mirrors the IF/ID stall exactly.
        //
        // SINGLE read port only: the in-order core (the sole SYNC_READ user)
        // never reads instruction2, and an initialized 2-read-port RAM can't
        // take its MIF on MAX 10 (uninferred, B006). One read port keeps the
        // program ROM in M9K. instruction2 is tied off (unconnected upstream).
        always @(posedge clk) if (!hold)
            instruction <= mem[idx];
        always @(*) instruction2 = 32'b0;
    end else begin : g_comb_fetch
        // Combinational read — original behavior, unchanged.
        always @(*) begin
            instruction  = mem[idx];
            instruction2 = mem[idx2];
        end
    end endgenerate

endmodule
