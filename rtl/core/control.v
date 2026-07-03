module control (
    input  wire [6:0] opcode,   // Opcode field from the instruction

    output reg        RegWrite, // Enable register file writeback
    output reg        MemRead,  // Enable memory read (for loads)
    output reg        MemWrite, // Enable memory write (for stores)
    output reg        MemToReg, // Select memory data instead of ALU result
    output reg        ALUSrc,   // Select immediate instead of rs2
    output reg        Branch,   // Marks instruction as a branch
    output reg [1:0]  ALUOp     // High-level ALU control used by ALU control unit
);

    always @(*) begin
        // Default control signals (NOP) – keeps hardware in a safe state
        RegWrite = 1'b0;
        MemRead  = 1'b0;
        MemWrite = 1'b0;
        MemToReg = 1'b0;
        ALUSrc   = 1'b0;
        Branch   = 1'b0;
        ALUOp    = 2'b00;

        case (opcode)

            7'b0110011: begin
                // R-type ALU instructions (ADD, SUB, AND, OR, XOR, SLT,
                // SLTU, SLL, SRL, SRA)
                RegWrite = 1'b1;      // write result back to rd
                ALUSrc   = 1'b0;      // use register rs2
                MemToReg = 1'b0;      // write ALU result
                Branch   = 1'b0;
                ALUOp    = 2'b10;     // ALUCLASS_RTYPE: funct3 + funct7[5]
            end

            7'b0010011: begin
                // I-type ALU instructions (ADDI, ANDI, ORI, XORI, SLTI,
                // SLTIU, SLLI, SRLI, SRAI)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;      // use immediate value
                MemToReg = 1'b0;      // ALU result goes to rd
                ALUOp    = 2'b11;     // ALUCLASS_ITYPE: funct3 only, so
                                      // immediate bits can't spoof funct7
                                      // (BUGLOG B004); instr[30] still
                                      // selects SRLI/SRAI as the ISA defines
            end

            7'b0000011: begin
                // Load instructions (LW)
                RegWrite = 1'b1;      // write loaded data to rd
                ALUSrc   = 1'b1;      // base + offset
                MemRead  = 1'b1;      // enable memory read
                MemToReg = 1'b1;      // write memory output instead of ALU result
                ALUOp    = 2'b00;     // ALU performs ADD
            end

            7'b0100011: begin
                // Store instructions (SW)
                ALUSrc   = 1'b1;      // base + offset
                MemWrite = 1'b1;      // enable memory write
                ALUOp    = 2'b00;     // ALU performs ADD
            end

            7'b1100011: begin
                // Branch instructions (BEQ/BNE/BLT/BGE/BLTU/BGEU).
                // The condition comes from the dedicated branch_unit
                // (decision D007/B2); the ALU output is unused here.
                Branch   = 1'b1;      // signal branch logic
                ALUSrc   = 1'b0;      // comparator uses rs1 and rs2
                ALUOp    = 2'b01;     // don't-care (legacy SUB class)
            end

            default: begin
                // Unsupported opcodes → behave like NOP (defaults already applied)
            end

        endcase
    end

endmodule
