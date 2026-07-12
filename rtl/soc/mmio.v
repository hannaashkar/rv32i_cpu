// ============================================================================
// mmio — memory-mapped I/O block (IO region = addr[31:28] == 4)
//
// Map (word access only):
//   0x4000_0000  RW  LEDs        [9:0]
//   0x4000_0004  R   switches    [9:0]
//   0x4000_0008  W   test-end    (harness protocol, no register here)
//   0x4000_000C  RW  HEXLO       {HEX3,HEX2,HEX1,HEX0} raw segment bytes
//   0x4000_0010  W   sim console (harness protocol, no register here)
//   0x4000_0014  RW  HEXHI       {16'b0,HEX5,HEX4}     raw segment bytes
//
// HEX registers (D023): each byte drives one 7-segment digit directly,
// bit i = segment i, bit 7 = decimal point. The board's displays are
// ACTIVE-LOW (0 lights a segment) and the hardware does NOT invert or
// decode — software owns the font (sw/common/rv32.h). Reset value is
// all-ones = every segment dark. Both HEX registers read back what was
// written so the ISS can lockstep-compare them like any other state.
// ============================================================================
module mmio(
    input  wire        clk,
    input  wire        reset,

    // Read and write ports are independently addressed (D013): the OoO
    // core reads MMIO from the load pipe while the store queue commits.
    // The in-order top drives both with the same MEM-stage address.
    input  wire [31:0] raddr,
    output reg  [31:0] rdata,     // read-back data into the CPU

    input  wire [31:0] waddr,
    input  wire [31:0] wdata,
    input  wire        we,        // write-enable (committed store)

    // Physical FPGA hardware
    output reg  [9:0]  leds,      // LED register (writeable)
    input  wire [9:0]  switches,  // Switch register (read-only)
    output wire [7:0]  hex0,      // 7-seg digits, raw active-low segments
    output wire [7:0]  hex1,
    output wire [7:0]  hex2,
    output wire [7:0]  hex3,
    output wire [7:0]  hex4,
    output wire [7:0]  hex5
);

    reg [31:0] hexlo;             // {HEX3,HEX2,HEX1,HEX0}
    reg [15:0] hexhi;             // {HEX5,HEX4}

    // ---------------------------------------------------------
    // 2-flop synchronizer on the slide switches (audit 2026-07-11).
    // SW pins are asynchronous mechanical inputs feeding the CPU load
    // path; the .sdc false-path silences STA on them but provides no
    // metastability protection — and the D023 demo is switch-driven.
    // No reset on purpose: by the time the first load can retire the
    // chain has long settled, and reset-free flops pack better. The
    // ISS mirrors switches as a constant, so the 2-cycle sampling
    // delay is lockstep-invisible (the harness drives them statically).
    // ---------------------------------------------------------
    reg [9:0] sw_meta, sw_sync;
    always @(posedge clk) begin
        sw_meta <= switches;
        sw_sync <= sw_meta;
    end

    // ---------------------------------------------------------
    // Write side. On reset LEDs clear and every display goes dark
    // (active-low segments -> all-ones). CPU stores update the
    // addressed register; unmapped IO addresses are ignored.
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            leds  <= 10'b0;
            hexlo <= 32'hFFFFFFFF;
            hexhi <= 16'hFFFF;
        end else if (we) begin
            case (waddr)
                32'h40000000: leds  <= wdata[9:0];
                32'h4000000C: hexlo <= wdata;
                32'h40000014: hexhi <= wdata[15:0];
                default: ;                       // test-end/console: harness-only
            endcase
        end
    end

    assign hex0 = hexlo[7:0];
    assign hex1 = hexlo[15:8];
    assign hex2 = hexlo[23:16];
    assign hex3 = hexlo[31:24];
    assign hex4 = hexhi[7:0];
    assign hex5 = hexhi[15:8];

    // ---------------------------------------------------------
    // Memory-Mapped Read Logic (Combinational)
    // Every readable register reads back its live value; anything
    // else returns zero.
    // ---------------------------------------------------------
    always @(*) begin
        case (raddr)
            32'h40000000: rdata = {22'b0, leds};      // zero-extend LED bits
            32'h40000004: rdata = {22'b0, sw_sync};   // synchronized switch bits
            32'h4000000C: rdata = hexlo;
            32'h40000014: rdata = {16'b0, hexhi};
            default:      rdata = 32'b0;              // unmapped address
        endcase
    end

endmodule
