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
//   * Read timing is selected by SYNC_READ (BUGLOG B006, decision D016):
//       SYNC_READ=0 — combinational read (original D010/Eb behavior);
//         costs FFs/LEs instead of block RAM. Simulation-only legacy path.
//       SYNC_READ=1 — registered read: the read word is captured in a read
//         register, the M9K block-RAM pattern. read_data is then valid ONE
//         CYCLE after the address — in WB, not MEM. Both cores fold their
//         former MEM/WB mem_data latch into this register (IPC-neutral).
//   * At most one access consumer is in flight per port pair and
//     mem_read/mem_write never target the same word on the same edge in a
//     way software can observe (in-order: one MEM-stage access at a time),
//     so read-during-write returns old data harmlessly. The altsyncram arm
//     pins this down explicitly (OLD_DATA) so hardware matches the
//     behavioral arm's nonblocking-assignment semantics bit-for-bit.
//   * addr bits above the memory range alias (index is a bit-slice).
//   * MMIO (0x4xxxxxxx) never reaches this module — cpu_pipeline gates
//     mem_read/mem_write with ~is_io. MMIO registers are word-access-only.
//
// Initialization:
//   * Simulation: optional +dmem=<hexfile> plusarg (for .data sections).
//     SIM_BIG_MEM (set by the Verilator build) selects a benchmark-sized
//     memory; the synthesis default stays board-sized.
//   * Synthesis (D023): the SYNC_READ arm instantiates an explicit
//     altsyncram initialized from INIT_FILE (default dmem.mif, resolved
//     relative to the Quartus project dir). Explicit instantiation is
//     REQUIRED on MAX 10 (B006/D022): Quartus 20.1 refuses to MIF-init any
//     inferred RAM, and needs the qsf's ERAM internal-configuration mode.
//     This is what lets a board program find its .data image (the MLP
//     weights) in memory at power-up — there is no loader.
// ============================================================================
module dmem #(
`ifdef SIM_BIG_MEM
    parameter DEPTH_WORDS = 65536,     // 256 KB for benchmarks in simulation
`else
    parameter DEPTH_WORDS = 16384,     // 64 KB on the FPGA (D023: MLP data)
`endif
    parameter SYNC_READ   = 0,         // 1 = registered read (M9K block RAM)
    parameter INIT_FILE   = "dmem.mif" // synthesis contents (SYNC_READ arm)
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

    localparam AW = $clog2(DEPTH_WORDS);

    wire [AW-1:0] ridx = raddr[AW+1:2];
    wire [AW-1:0] widx = waddr[AW+1:2];

    // ------------------------------------------------------
    // Write byte enables + lane-replicated data (shared by every arm).
    // Byte-enable form (B006) — one enable per byte lane, write data
    // replicated across lanes so the enables alone select what is written.
    // This is both the coding pattern Quartus recognizes for byte-enabled
    // M9K RAM and, unchanged, the byteena_a input of the explicit
    // altsyncram below.
    //   funct3[1:0]: 00 SB (one byte)  01 SH (one half)  10 SW (full word)
    // ------------------------------------------------------
    reg [3:0] wbe;
    always @(*) begin
        if (!mem_write)
            wbe = 4'b0000;
        else begin
            case (wfunct3[1:0])
                2'b00:   wbe = 4'b0001 << waddr[1:0];         // SB
                2'b01:   wbe = waddr[1] ? 4'b1100 : 4'b0011;  // SH
                default: wbe = 4'b1111;                       // SW
            endcase
        end
    end

    // Lane-replicated store data: every enabled lane sees the byte it
    // must receive (SB: byte in all four lanes; SH: half in both halves).
    wire [31:0] wlanes = (wfunct3[1:0] == 2'b00) ? {4{write_data[7:0]}}  :
                         (wfunct3[1:0] == 2'b01) ? {2{write_data[15:0]}} :
                                                   write_data;

    // ------------------------------------------------------
    // Read: fetch the word, then extract the addressed byte/half
    // and sign/zero extend according to funct3.
    //   000 LB   001 LH   010 LW   100 LBU   101 LHU
    // Two elaboration-time variants — see SYNC_READ in the header.
    // ------------------------------------------------------
    generate if (SYNC_READ != 0) begin : g_sync_read

        // Registered read (B006/D016). The word register is the M9K's
        // embedded read register; the lane controls (addr[1:0], funct3,
        // read enable) are registered alongside it so the extraction below
        // always operates on matched values.
        reg [1:0]  rlow_q;    // addr[1:0] — byte/half lane select
        reg [2:0]  rf3_q;     // size + sign
        reg        rden_q;    // read enable, pipelined

        always @(posedge clk) begin
            rlow_q  <= raddr[1:0];
            rf3_q   <= rfunct3;
            rden_q  <= mem_read;
        end

`ifdef VERILATOR
        // Behavioral storage: word array, registered read, byte-lane write.
        reg [31:0] memory [0:DEPTH_WORDS-1];
        reg [31:0] rword_q;   // M9K read-data register

        reg [8*256:1] hexfile;             // +dmem=<path> data image
        integer i;
        initial begin
            for (i = 0; i < DEPTH_WORDS; i = i + 1)
                memory[i] = 32'h0;
            if ($value$plusargs("dmem=%s", hexfile))
                $readmemh(hexfile, memory);
        end

        always @(posedge clk) begin
            rword_q <= memory[ridx];
            if (wbe[0]) memory[widx][7:0]   <= wlanes[7:0];
            if (wbe[1]) memory[widx][15:8]  <= wlanes[15:8];
            if (wbe[2]) memory[widx][23:16] <= wlanes[23:16];
            if (wbe[3]) memory[widx][31:24] <= wlanes[31:24];
        end
`else
        // Synthesis: one explicit altsyncram in simple-dual-port mode
        // (port A = write with byte enables, port B = registered-address
        // read), MIF-initialized. Explicit instantiation is REQUIRED for
        // MIF init on MAX 10 (B006/D022) — an inferred RAM either rejects
        // the init or bakes it into logic. The registered read address is
        // the same one-cycle read the behavioral arm implements by
        // registering the data. OLD_DATA read-during-write matches the
        // behavioral arm's nonblocking-write semantics exactly.
        wire [31:0] rword_q;
        altsyncram #(
            .operation_mode("DUAL_PORT"),
            .width_a(32),
            .widthad_a(AW),
            .numwords_a(DEPTH_WORDS),
            .width_byteena_a(4),
            .byte_size(8),
            .width_b(32),
            .widthad_b(AW),
            .numwords_b(DEPTH_WORDS),
            .address_reg_b("CLOCK0"),
            .outdata_reg_b("UNREGISTERED"),
            .init_file(INIT_FILE),
            .intended_device_family("MAX 10"),
            .ram_block_type("M9K"),
            .lpm_type("altsyncram"),
            .read_during_write_mode_mixed_ports("OLD_DATA")
        ) U_RAM (
            .clock0(clk),
            .wren_a(mem_write),
            .address_a(widx),
            .data_a(wlanes),
            .byteena_a(wbe),
            .address_b(ridx),
            .q_b(rword_q)
        );
`endif

        wire [7:0]  rbyte = rword_q[rlow_q*8     +: 8];
        wire [15:0] rhalf = rword_q[rlow_q[1]*16 +: 16];

        always @(*) begin
            if (!rden_q)
                read_data = 32'b0;
            else begin
                case (rf3_q)
                    3'b000:  read_data = {{24{rbyte[7]}},  rbyte};  // LB
                    3'b001:  read_data = {{16{rhalf[15]}}, rhalf};  // LH
                    3'b100:  read_data = {24'b0, rbyte};            // LBU
                    3'b101:  read_data = {16'b0, rhalf};            // LHU
                    default: read_data = rword_q;                   // LW
                endcase
            end
        end

    end else begin : g_comb_read

        // Combinational read — original behavior, unchanged. Behavioral
        // storage only: no synthesis user remains (both cores are
        // SYNC_READ=1 since D016/D018), and this arm cannot be M9K anyway.
        reg [31:0] memory [0:DEPTH_WORDS-1];

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

        always @(posedge clk) begin
            if (wbe[0]) memory[widx][7:0]   <= wlanes[7:0];
            if (wbe[1]) memory[widx][15:8]  <= wlanes[15:8];
            if (wbe[2]) memory[widx][23:16] <= wlanes[23:16];
            if (wbe[3]) memory[widx][31:24] <= wlanes[31:24];
        end

    end endgenerate

endmodule
