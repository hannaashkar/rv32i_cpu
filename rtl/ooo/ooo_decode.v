// ============================================================================
// ooo_decode — one-slot RV32I+Zicsr decoder into the OoO uop format
//
// Purpose:    Pure combinational decode of one instruction into the uop
//             fields the rename/issue stages need (D013). Two instances
//             make the 2-wide decode stage.
// Key points vs the in-order decoder:
//   * rs1_used/rs2_used are exact per format — immediate bits can never
//     create false dependencies (kills the old watch-list quirk).
//   * The ALU control code is resolved here (flat funct3 scheme, D006)
//     so the issue queue carries a final 4-bit alu op.
//   * Branch targets (pc+imm) are precomputed here; the imm field of a
//     branch uop carries the TARGET.
//   * JAL is not a branch downstream: decode redirects the frontend
//     itself, and the uop becomes "rd = pass-through(pc+4)" on the ALU
//     port. JALR resolves on the branch port.
// ============================================================================
module ooo_decode (
    input  wire [31:0] instr,
    input  wire [31:0] pc,

    output reg         is_branch,   // conditional branch
    output wire        is_jal,
    output wire        is_jalr,
    output reg         is_load,
    output reg         is_store,
    output reg         is_csr,
    output reg         wr,          // writes rd (before rd==x0 squash)
    output reg         rs1_used,
    output reg         rs2_used,
    output reg  [3:0]  alu_ctrl,    // alu_ops.vh encoding
    output reg         alu_src,     // operand B = imm
    output reg         alu_apc,     // operand A = pc (AUIPC)
    output reg  [31:0] imm,         // immediate / branch target / csr addr
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output wire [2:0]  funct3,
    output wire [31:0] jal_target   // decode-redirect target for JAL
);

`include "alu_ops.vh"

    wire [6:0] opcode = instr[6:0];
    wire [6:0] funct7 = instr[31:25];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign is_jal  = (opcode == 7'b1101111);
    assign is_jalr = (opcode == 7'b1100111);

    // immediates
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7],
                         instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                         instr[20], instr[30:21], 1'b0};

    assign jal_target = pc + imm_j;

    // flat funct3 ALU decode (same scheme as alu_control.v / D006)
    function [3:0] alu_decode;
        input [2:0] f3;
        input       f7b5;      // instr[30], qualified by format
        input       is_rtype;  // funct7 participates
        begin
            case (f3)
                3'b000: alu_decode = (is_rtype && f7b5) ? ALU_SUB : ALU_ADD;
                3'b001: alu_decode = ALU_SLL;
                3'b010: alu_decode = ALU_SLT;
                3'b011: alu_decode = ALU_SLTU;
                3'b100: alu_decode = ALU_XOR;
                3'b101: alu_decode = f7b5 ? ALU_SRA : ALU_SRL;
                3'b110: alu_decode = ALU_OR;
                default: alu_decode = ALU_AND;
            endcase
        end
    endfunction

    always @(*) begin
        is_branch = 1'b0;
        is_load   = 1'b0;
        is_store  = 1'b0;
        is_csr    = 1'b0;
        wr        = 1'b0;
        rs1_used  = 1'b0;
        rs2_used  = 1'b0;
        alu_ctrl  = ALU_ADD;
        alu_src   = 1'b0;
        alu_apc   = 1'b0;
        imm       = imm_i;

        case (opcode)
            7'b0110011: begin                       // R-type ALU
                wr = 1'b1; rs1_used = 1'b1; rs2_used = 1'b1;
                alu_ctrl = alu_decode(funct3, funct7[5], 1'b1);
            end
            7'b0010011: begin                       // I-type ALU
                wr = 1'b1; rs1_used = 1'b1; alu_src = 1'b1;
                // shifts consult instr[30] even in I form (SRAI)
                alu_ctrl = alu_decode(funct3,
                                      (funct3 == 3'b101) && funct7[5], 1'b1);
            end
            7'b0000011: begin                       // loads
                is_load = 1'b1; wr = 1'b1; rs1_used = 1'b1; alu_src = 1'b1;
            end
            7'b0100011: begin                       // stores
                is_store = 1'b1; rs1_used = 1'b1; rs2_used = 1'b1;
                imm = imm_s;
            end
            7'b1100011: begin                       // conditional branches
                is_branch = 1'b1; rs1_used = 1'b1; rs2_used = 1'b1;
                imm = pc + imm_b;                   // TARGET precomputed
            end
            7'b0110111: begin                       // LUI
                wr = 1'b1; alu_src = 1'b1; alu_ctrl = ALU_PASS_B;
                imm = imm_u;
            end
            7'b0010111: begin                       // AUIPC
                wr = 1'b1; alu_src = 1'b1; alu_apc = 1'b1;
                imm = imm_u;
            end
            7'b1101111: begin                       // JAL: link via ALU port
                wr = 1'b1; alu_src = 1'b1; alu_ctrl = ALU_PASS_B;
                imm = pc + 32'd4;                   // rd = pc+4
            end
            7'b1100111: begin                       // JALR: branch port
                wr = 1'b1; rs1_used = 1'b1; alu_src = 1'b1;
                imm = imm_i;                        // target = rs1+imm (EX)
            end
            7'b1110011: begin                       // SYSTEM
                if (funct3 != 3'b000) begin
                    is_csr = 1'b1; wr = 1'b1;
                    rs1_used = ~funct3[2];          // register forms only
                    imm = {20'b0, instr[31:20]};    // CSR address
                end
            end
            default: ;                              // NOP (incl. FENCE)
        endcase
    end

endmodule
