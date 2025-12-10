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
                // R-type ALU instructions (ADD, SUB, AND, OR, XOR, SLT, ...)
                RegWrite = 1'b1;      // write result back to rd
                ALUSrc   = 1'b0;      // use register rs2
                MemToReg = 1'b0;      // write ALU result
                Branch   = 1'b0;
                ALUOp    = 2'b10;     // use funct3/funct7 to choose ALU op
            end

            7'b0010011: begin
                // I-type ALU instructions (ADDI, ANDI, ORI, XORI, SLTI, ...)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;      // use immediate value
                MemToReg = 1'b0;      // ALU result goes to rd
                ALUOp    = 2'b10;     // same ALU decoding as R-type
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
                // Branch instructions (BEQ/BNE)
                Branch   = 1'b1;      // signal branch logic
                ALUSrc   = 1'b0;      // compare rs1 and rs2
                ALUOp    = 2'b01;     // ALU performs SUB for comparison
            end

            default: begin
                // Unsupported opcodes → behave like NOP (defaults already applied)
            end

        endcase
    end

endmodule
