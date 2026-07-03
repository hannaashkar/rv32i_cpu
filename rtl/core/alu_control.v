// ============================================================================
// alu_control — flat funct3-based ALU operation decode (decision D006/A2)
//
// Purpose:    Turn the operation class from control.v plus the instruction's
//             funct fields into a concrete ALU operation.
// Interfaces: ALUOp (2-bit class, see alu_ops.vh), funct3, funct7 -> alu_control.
// Assumptions:
//   * funct7 participates exactly where RV32I defines it:
//       - R-type funct3=000: funct7[5] selects ADD/SUB
//       - funct3=101 (both R- and I-type): funct7[5] selects SRL/SRA
//       - I-type funct3=000 is ALWAYS ADDI — immediate bits can no longer
//         spoof SUB (this decode structure is the fix for BUGLOG B004)
//   * Illegal funct7 patterns are not yet detected (no traps); they decode
//     as the nearest legal operation.
// ============================================================================
module alu_control (
    input  wire [1:0] ALUOp,      // operation class from control.v
    input  wire [2:0] funct3,     // instruction funct3 field
    input  wire [6:0] funct7,     // instruction funct7 field (bit 5 used)
    output reg  [3:0] alu_control // operation for the ALU
);

`include "alu_ops.vh"

    wire is_rtype = (ALUOp == ALUCLASS_RTYPE);

    always @(*) begin
        case (ALUOp)

            ALUCLASS_ADD: alu_control = ALU_ADD;   // load/store address
            ALUCLASS_SUB: alu_control = ALU_SUB;   // branch compare

            // R-type and I-type ALU operations: funct3 selects the op.
            ALUCLASS_RTYPE,
            ALUCLASS_ITYPE: begin
                case (funct3)
                    3'b000: alu_control = (is_rtype && funct7[5]) ? ALU_SUB
                                                                  : ALU_ADD;
                    3'b001: alu_control = ALU_SLL;
                    3'b010: alu_control = ALU_SLT;
                    3'b011: alu_control = ALU_SLTU;
                    3'b100: alu_control = ALU_XOR;
                    3'b101: alu_control = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_control = ALU_OR;
                    3'b111: alu_control = ALU_AND;
                endcase
            end

            default: alu_control = ALU_ADD;
        endcase
    end

endmodule
