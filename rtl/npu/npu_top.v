// ============================================================================
// npu_top — MMIO front end of the 4x4 int8 systolic NPU
// (decision D014; docs/NPU.md is the binding spec, incl. the register map)
//
// Purpose:    A/B staging registers, CTRL/STATUS/ID decode, combinational
//             read mux, and the busy/busy_next interlock exports.
// Interfaces: raddr/rdata — combinational read port. ALL reads are
//             side-effect-free (safe under speculative execution).
//             we/waddr/wdata — one committed store per cycle. The core
//             guarantees `we` only while the array is idle (OoO: SQ drain
//             backpressure via mw_ready; in-order: EX-stage stall) —
//             asserted below.
//             busy      — array running (STATUS bit0; never observably 1,
//                         see the interlock argument in docs/NPU.md)
//             busy_next — busy OR a GO landing this cycle; the cores'
//                         stall/replay condition (closes the 1-cycle gap
//                         between the GO store and the busy register).
// Assumes:    word-aligned LW/SW access only. Decode is exact: misaligned
//             or sub-word addresses fall into the unmapped case (read 0 /
//             write dropped). Stores write the full rs2 word regardless
//             of funct3 — same documented quirk as mmio.v.
// ============================================================================
module npu_top (
    input  wire        clk,
    input  wire        reset,

    input  wire [31:0] raddr,
    output reg  [31:0] rdata,

    input  wire        we,
    input  wire [31:0] waddr,
    input  wire [31:0] wdata,

    output wire        busy,
    output wire        busy_next
);

    localparam [31:0] NPU_ID = 32'h4E505501;      // "NPU", version 1

    // A/B staging registers: a_r[i] byte k = A[i][k], b_r[k] byte j = B[k][j]
    reg [31:0] a_r [0:3];
    reg [31:0] b_r [0:3];

    // CTRL write decode
    wire w_ctrl = we && (waddr == 32'h50000008);
    wire go_w   = w_ctrl && wdata[0];
    wire clr_w  = w_ctrl && wdata[1];

    assign busy_next = busy | go_w;

    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 4; i = i + 1) begin
                a_r[i] <= 32'b0;
                b_r[i] <= 32'b0;
            end
        end else if (we) begin
            case (waddr)
                32'h50000010: a_r[0] <= wdata;
                32'h50000014: a_r[1] <= wdata;
                32'h50000018: a_r[2] <= wdata;
                32'h5000001C: a_r[3] <= wdata;
                32'h50000020: b_r[0] <= wdata;
                32'h50000024: b_r[1] <= wdata;
                32'h50000028: b_r[2] <= wdata;
                32'h5000002C: b_r[3] <= wdata;
                default: ;                        // CTRL handled by the
            endcase                               // array; R/O + unmapped
        end                                       // writes are dropped
    end

    // the array
    wire         done;
    wire [511:0] c_flat;

    npu_array ARR (
        .clk    (clk),
        .reset  (reset),
        .go     (go_w),
        .clr    (clr_w),
        .amat   ({a_r[3], a_r[2], a_r[1], a_r[0]}),
        .bmat   ({b_r[3], b_r[2], b_r[1], b_r[0]}),
        .busy   (busy),
        .done   (done),
        .c_flat (c_flat)
    );

    // combinational read mux (exact-address decode, like mmio.v)
    always @(*) begin
        case (raddr)
            32'h50000000: rdata = NPU_ID;
            32'h50000004: rdata = {30'b0, done, busy};
            32'h50000010: rdata = a_r[0];
            32'h50000014: rdata = a_r[1];
            32'h50000018: rdata = a_r[2];
            32'h5000001C: rdata = a_r[3];
            32'h50000020: rdata = b_r[0];
            32'h50000024: rdata = b_r[1];
            32'h50000028: rdata = b_r[2];
            32'h5000002C: rdata = b_r[3];
            32'h50000040: rdata = c_flat[ 32*0 +: 32];
            32'h50000044: rdata = c_flat[ 32*1 +: 32];
            32'h50000048: rdata = c_flat[ 32*2 +: 32];
            32'h5000004C: rdata = c_flat[ 32*3 +: 32];
            32'h50000050: rdata = c_flat[ 32*4 +: 32];
            32'h50000054: rdata = c_flat[ 32*5 +: 32];
            32'h50000058: rdata = c_flat[ 32*6 +: 32];
            32'h5000005C: rdata = c_flat[ 32*7 +: 32];
            32'h50000060: rdata = c_flat[ 32*8 +: 32];
            32'h50000064: rdata = c_flat[ 32*9 +: 32];
            32'h50000068: rdata = c_flat[32*10 +: 32];
            32'h5000006C: rdata = c_flat[32*11 +: 32];
            32'h50000070: rdata = c_flat[32*12 +: 32];
            32'h50000074: rdata = c_flat[32*13 +: 32];
            32'h50000078: rdata = c_flat[32*14 +: 32];
            32'h5000007C: rdata = c_flat[32*15 +: 32];
            default:      rdata = 32'b0;          // unmapped reads: 0
        endcase
    end

`ifdef VERILATOR
    // core-side interlocks must make a write-while-busy impossible
    always @(posedge clk) begin
        if (!reset && we && busy)
            $fatal(1, "npu_top: MMIO write while busy (interlock violated)");
    end
`endif

endmodule
