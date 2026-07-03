// ============================================================================
// control — main opcode-level decoder
//
// Purpose:    Classify the instruction by opcode and produce the pipeline
//             control signals carried down ID/EX.
// Interfaces: opcode -> {RegWrite, MemRead, MemWrite, MemToReg, ALUSrc,
//             ALUAPc, Branch, ALUOp}.
//             ALUOp is the 3-bit operation CLASS (see alu_ops.vh);
//             alu_control refines it with funct3/funct7 in EX.
//             ALUAPc = 1 routes pcE into ALU operand A (AUIPC; jumps reuse
//             this path, decision D009/D1).
// Assumptions:
//   * Unsupported opcodes decode as NOPs — illegal-instruction traps are a
//     later stage.
// ============================================================================
module control (
    input  wire [6:0] opcode,   // Opcode field from the instruction

    output reg        RegWrite, // Enable register file writeback
    output reg        MemRead,  // Enable memory read (for loads)
    output reg        MemWrite, // Enable memory write (for stores)
    output reg        MemToReg, // Select memory data instead of ALU result
    output reg        ALUSrc,   // Operand B: immediate instead of rs2
    output reg        ALUAPc,   // Operand A: pc instead of rs1 (AUIPC)
    output reg        Branch,   // Marks instruction as a conditional branch
    output reg        Jal,      // JAL: unconditional jump, target = pc+imm
    output reg        Jalr,     // JALR: unconditional jump, target = rs1+imm
    output reg [2:0]  ALUOp     // ALU operation class (alu_ops.vh)
);

`include "alu_ops.vh"

    always @(*) begin
        // Default control signals (NOP) - keeps hardware in a safe state
        RegWrite = 1'b0;
        MemRead  = 1'b0;
        MemWrite = 1'b0;
        MemToReg = 1'b0;
        ALUSrc   = 1'b0;
        ALUAPc   = 1'b0;
        Branch   = 1'b0;
        Jal      = 1'b0;
        Jalr     = 1'b0;
        ALUOp    = ALUCLASS_ADD;

        case (opcode)

            7'b0110011: begin
                // R-type ALU (ADD, SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA)
                RegWrite = 1'b1;
                ALUSrc   = 1'b0;               // use register rs2
                ALUOp    = ALUCLASS_RTYPE;     // funct3 + funct7[5]
            end

            7'b0010011: begin
                // I-type ALU (ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI,
                // SRLI, SRAI). ITYPE class ignores funct7 except the
                // ISA-defined SRLI/SRAI bit — immediate bits can't spoof
                // funct7 (BUGLOG B004).
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;
                ALUOp    = ALUCLASS_ITYPE;
            end

            7'b0000011: begin
                // Loads (LW; byte/half arrive with the sub-word stage)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;               // base + offset
                MemRead  = 1'b1;
                MemToReg = 1'b1;               // write memory data to rd
                ALUOp    = ALUCLASS_ADD;
            end

            7'b0100011: begin
                // Stores (SW)
                ALUSrc   = 1'b1;               // base + offset
                MemWrite = 1'b1;
                ALUOp    = ALUCLASS_ADD;
            end

            7'b1100011: begin
                // Conditional branches (BEQ/BNE/BLT/BGE/BLTU/BGEU).
                // Condition comes from branch_unit (D007/B2); ALU unused.
                Branch   = 1'b1;
                ALUSrc   = 1'b0;
                ALUOp    = ALUCLASS_SUB;       // don't-care
            end

            7'b0110111: begin
                // LUI: rd = U-immediate (ALU passes operand B through)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;
                ALUOp    = ALUCLASS_PASSB;
            end

            7'b0010111: begin
                // AUIPC: rd = pc + U-immediate
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;               // operand B = U-immediate
                ALUAPc   = 1'b1;               // operand A = pc
                ALUOp    = ALUCLASS_ADD;
            end

            7'b1101111: begin
                // JAL: rd = pc+4, jump to pc + J-immediate.
                // Target uses the EX branch-target adder; the jump rides
                // the mispredict/redirect path and trains the BTB
                // (decision D008/C1).
                RegWrite = 1'b1;
                Jal      = 1'b1;
            end

            7'b1100111: begin
                // JALR: rd = pc+4, jump to (rs1 + I-immediate) & ~1.
                // The ALU computes the target (rs1 forwarded normally).
                RegWrite = 1'b1;
                Jalr     = 1'b1;
                ALUSrc   = 1'b1;
                ALUOp    = ALUCLASS_ADD;
            end

            default: begin
                // Unsupported opcodes behave like NOPs (defaults above)
            end

        endcase
    end

endmodule
