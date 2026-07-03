// ============================================================================
// imem — instruction memory (word-addressed, combinational read)
//
// Purpose:    Holds the program the core executes. Contents are loaded from
//             a hex file ($readmemh format: one 32-bit word per line,
//             little-endian instruction words, '//' comments allowed).
// Interfaces: pc (byte address from IF) -> instruction (combinational read).
// Assumptions / limitations:
//   * Combinational read preserves the original same-cycle fetch timing but
//     synthesizes to logic cells instead of M9K block RAM (BUGLOG B006 —
//     synchronous-read rework is a planned architectural change).
//   * pc bits above the memory range are ignored (memory aliases).
//
// Program loading:
//   * Synthesis: MEM_FILE, resolved relative to the Quartus project dir
//     (synth/), defaults to the original LED demo program.
//   * Simulation: pass +imem=<hexfile> at runtime; the Verilator harness
//     always does this, so programs swap without recompiling the model.
// ============================================================================
module imem #(
`ifdef SIM_BIG_MEM
    parameter DEPTH_WORDS = 65536,                      // 256 KB (benchmarks)
`else
    parameter DEPTH_WORDS = 1024,                       // 4 KB of program
`endif
    // Default program used by Quartus builds (path relative to synth/).
    // NOTE: keep the word "synthesis" out of trailing comments here —
    // Quartus parses "synthesis <x>" inside comments as a pragma.
    parameter MEM_FILE    = "../sw/demo/led_demo.hex"
)(
    input  wire [31:0] pc,           // byte address from Fetch stage
    output wire [31:0] instruction   // fetched instruction
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
    assign instruction = mem[pc[$clog2(DEPTH_WORDS)+1:2]];

endmodule
