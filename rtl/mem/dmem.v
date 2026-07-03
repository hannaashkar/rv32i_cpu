// ============================================================================
// dmem — data memory with sub-word access (word array + byte lanes)
//
// Purpose:    Backing store for loads/stores. Implements all RV32I access
//             sizes: LB/LBU/LH/LHU/LW and SB/SH/SW, selected by funct3.
// Interfaces: addr/write_data/funct3 from the MEM stage; read_data goes
//             back into the pipeline already extracted and sign/zero
//             extended.
// Assumptions:
//   * Accesses are naturally aligned (the C ABI guarantees this).
//     Misaligned behavior is undefined until traps exist.
//   * Combinational read (decision D010/Eb) — costs FFs instead of block
//     RAM (BUGLOG B006); the synchronous-read/BRAM rework is a separate
//     post-baseline stage.
//   * addr bits above the memory range alias (index is a bit-slice).
//   * MMIO (0x4xxxxxxx) never reaches this module — cpu_pipeline gates
//     mem_read/mem_write with ~is_io. MMIO registers are word-access-only.
//
// Initialization:
//   * Optional +dmem=<hexfile> plusarg in simulation (for .data sections).
//   * SIM_BIG_MEM (set by the Verilator build) selects a benchmark-sized
//     memory; the synthesis default stays small.
// ============================================================================
module dmem #(
`ifdef SIM_BIG_MEM
    parameter DEPTH_WORDS = 65536      // 256 KB for benchmarks in simulation
`else
    parameter DEPTH_WORDS = 256        // 1 KB on the FPGA (FF-based today)
`endif
)(
    // Read and write ports are independently addressed so the OoO core
    // can execute a load while the store queue commits an older store
    // (D013). The in-order top drives both with the same MEM-stage
    // address, preserving its original behavior exactly.
    input  wire        clk,
    input  wire        mem_read,       // read enable
    input  wire [31:0] raddr,          // load byte address
    input  wire [2:0]  rfunct3,        // load size + sign (RV32I encoding)
    output reg  [31:0] read_data,      // extracted + extended load data

    input  wire        mem_write,      // write enable
    input  wire [31:0] waddr,          // store byte address
    input  wire [31:0] write_data,     // rs2, LSB-justified
    input  wire [2:0]  wfunct3         // store size
);

    reg [31:0] memory [0:DEPTH_WORDS-1];

    wire [$clog2(DEPTH_WORDS)-1:0] ridx = raddr[$clog2(DEPTH_WORDS)+1:2];
    wire [$clog2(DEPTH_WORDS)-1:0] widx = waddr[$clog2(DEPTH_WORDS)+1:2];

`ifdef VERILATOR
    reg [8*256:1] hexfile;             // +dmem=<path> data image
    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            memory[i] = 32'h0;
        if ($value$plusargs("dmem=%s", hexfile))
            $readmemh(hexfile, memory);
    end
`endif

    // ------------------------------------------------------
    // Read: fetch the word, then extract the addressed byte/half
    // and sign/zero extend according to funct3.
    //   000 LB   001 LH   010 LW   100 LBU   101 LHU
    // ------------------------------------------------------
    wire [31:0] rword = memory[ridx];
    wire [7:0]  rbyte = rword[raddr[1:0]*8 +: 8];
    wire [15:0] rhalf = rword[raddr[1]*16 +: 16];

    always @(*) begin
        if (!mem_read)
            read_data = 32'b0;
        else begin
            case (rfunct3)
                3'b000:  read_data = {{24{rbyte[7]}},  rbyte};  // LB
                3'b001:  read_data = {{16{rhalf[15]}}, rhalf};  // LH
                3'b100:  read_data = {24'b0, rbyte};            // LBU
                3'b101:  read_data = {16'b0, rhalf};            // LHU
                default: read_data = rword;                     // LW
            endcase
        end
    end

    // ------------------------------------------------------
    // Write: byte-lane update selected by funct3[1:0] and addr[1:0].
    //   00 SB (one byte)   01 SH (one half)   10 SW (full word)
    // ------------------------------------------------------
    always @(posedge clk) begin
        if (mem_write) begin
            case (wfunct3[1:0])
                2'b00:   memory[widx][waddr[1:0]*8 +: 8] <= write_data[7:0];
                2'b01:   memory[widx][waddr[1]*16 +: 16] <= write_data[15:0];
                default: memory[widx]                    <= write_data;
            endcase
        end
    end

endmodule
