

module control (

    input  wire [6:0] opcode,

    output reg        RegWrite,
    output reg        MemRead,
    output reg        MemWrite,
    output reg        MemToReg,
    output reg        ALUSrc,
    output reg        Branch,
    output reg [1:0]  ALUOp
);
    always @(*) begin
        // Default values
        RegWrite = 1'b0;
        MemRead  = 1'b0;
        MemWrite = 1'b0;
        MemToReg = 1'b0;
        ALUSrc   = 1'b0;
        Branch   = 1'b0;
        ALUOp    = 2'b00;

        case (opcode)
            7'b0110011: begin
                // R-type (ADD, SUB, AND, OR, XOR, SLT, ...)
                RegWrite = 1'b1;
                ALUSrc   = 1'b0;      // use rs2
                MemRead  = 1'b0;
                MemWrite = 1'b0;
                MemToReg = 1'b0;      // write ALU result
                Branch   = 1'b0;
                ALUOp    = 2'b10;     // use funct3/funct7
            end

            7'b0010011: begin
                // I-type ALU (ADDI, ANDI, ORI, XORI, SLTI, ...)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;      // use immediate
                MemRead  = 1'b0;
                MemWrite = 1'b0;
                MemToReg = 1'b0;      // write ALU result
                Branch   = 1'b0;
                ALUOp    = 2'b10;     // still use funct3 (+ funct7 for some inst)
            end

            7'b0000011: begin
                // Load (LW)
                RegWrite = 1'b1;
                ALUSrc   = 1'b1;      // base + offset
                MemRead  = 1'b1;
                MemWrite = 1'b0;
                MemToReg = 1'b1;      // write data from memory
                Branch   = 1'b0;
                ALUOp    = 2'b00;     // ALU does ADD
            end

            7'b0100011: begin
                // Store (SW)
                RegWrite = 1'b0;
                ALUSrc   = 1'b1;      // base + offset
                MemRead  = 1'b0;
                MemWrite = 1'b1;
                MemToReg = 1'b0;      // don't care
                Branch   = 1'b0;
                ALUOp    = 2'b00;     // ALU does ADD
            end

            7'b1100011: begin
                // Branch (BEQ/BNE)
                RegWrite = 1'b0;
                ALUSrc   = 1'b0;      // compare rs1, rs2
                MemRead  = 1'b0;
                MemWrite = 1'b0;
                MemToReg = 1'b0;      // don't care
                Branch   = 1'b1;
                ALUOp    = 2'b01;     // ALU does SUB for compare
            end

            default: begin
                // NOP / unsupported → all zeros (already set by defaults)
            end
        endcase
    end

endmodule
