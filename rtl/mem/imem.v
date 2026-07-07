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

    reg [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
`ifdef VERILATOR
    reg [8*256:1] hexfile;           // +imem=<path> runtime override
`endif

    initial begin
        // Pad everything with NOPs so execution past the program's end
        // is harmless instead of X-propagation.
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'h00000013;   // addi x0, x0, 0

`ifdef VERILATOR
        if ($value$plusargs("imem=%s", hexfile))
            $readmemh(hexfile, mem);
        else
            $readmemh(MEM_FILE, mem);
`else
        $readmemh(MEM_FILE, mem);
`endif
    end

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
        always @(posedge clk) if (!hold) begin
            instruction  <= mem[idx];
            instruction2 <= mem[idx2];
        end
    end else begin : g_comb_fetch
        // Combinational read — original behavior, unchanged.
        always @(*) begin
            instruction  = mem[idx];
            instruction2 = mem[idx2];
        end
    end endgenerate

endmodule
