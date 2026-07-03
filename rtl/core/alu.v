// ============================================================================
// alu — 32-bit integer ALU for RV32I (decision D006/A2)
//
// Purpose:    Executes the operation selected by alu_control: arithmetic,
//             logic, signed/unsigned compare, and shifts.
// Interfaces: a, b (already forwarded / immediate-muxed) -> result, zero.
// Assumptions:
//   * Shift amount is b[4:0] (RV32I semantics: upper bits of rs2 / the
//     shamt field are ignored).
//   * One shifter is shared by SLL/SRL/SRA: for left shifts the input and
//     output are bit-reversed around an arithmetic right shifter (~200 LEs
//     instead of separate left/right shifters).
//   * zero flag = (result == 0); branch logic depends on it until the
//     dedicated comparator (decision D007/B2) lands.
// ============================================================================
module alu (
    input  wire [31:0] a,           // operand A (rs1, forwarded)
    input  wire [31:0] b,           // operand B (rs2 forwarded, or immediate)
    input  wire [3:0]  alu_control, // operation select (see alu_ops.vh)
    output reg  [31:0] result,      // operation result
    output wire        zero         // result == 0 (branch equality)
);

`include "alu_ops.vh"

    // ------------------------------------------------------------------
    // Shared shifter: reverse operand for left shifts, shift right,
    // reverse back. SRA extends with the sign bit via a 33-bit shift.
    // ------------------------------------------------------------------
    function [31:0] rev32(input [31:0] x);
        integer i;
        for (i = 0; i < 32; i = i + 1)
            rev32[i] = x[31-i];
    endfunction

    wire [4:0]  shamt    = b[4:0];
    wire        sh_left  = (alu_control == ALU_SLL);
    wire        sh_arith = (alu_control == ALU_SRA);

    wire [31:0] sh_in    = sh_left ? rev32(a) : a;
    wire [32:0] sh_ext   = {sh_arith & sh_in[31], sh_in};
    wire [32:0] sh_shift = $signed(sh_ext) >>> shamt;
    wire [31:0] sh_out   = sh_left ? rev32(sh_shift[31:0]) : sh_shift[31:0];

    always @(*) begin
        case (alu_control)
            ALU_ADD:    result = a + b;
            ALU_SUB:    result = a - b;
            ALU_AND:    result = a & b;
            ALU_OR:     result = a | b;
            ALU_XOR:    result = a ^ b;
            ALU_SLT:    result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (a < b)                   ? 32'd1 : 32'd0;
            ALU_SLL,
            ALU_SRL,
            ALU_SRA:    result = sh_out;
            ALU_PASS_B: result = b;
            default:    result = 32'b0;
        endcase
    end

    assign zero = (result == 32'b0);

endmodule
