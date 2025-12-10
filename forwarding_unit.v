// -------------------------------------------------------------
// Forwarding Unit
// -------------------------------------------------------------
// Detects data hazards in the EX stage and selects the correct
// source for ALU operands. This avoids unnecessary stalls.
// 
// Forwarding codes:
//   00 → use value from ID/EX pipeline register
//   10 → forward from EX/MEM stage (alu_resultM)
//   01 → forward from MEM/WB stage (resultW)
// -------------------------------------------------------------

module forwarding_unit (
    input  wire [4:0] rs1E,    // source register 1 in EX stage
    input  wire [4:0] rs2E,    // source register 2 in EX stage
    input  wire [4:0] rdM,     // destination register in MEM stage
    input  wire [4:0] rdW,     // destination register in WB stage
    input  wire       RegWriteM,
    input  wire       RegWriteW,

    output reg  [1:0] forwardAE,  // forwarding control for ALU operand A
    output reg  [1:0] forwardBE   // forwarding control for ALU operand B
);

    always @(*) begin
        // Default: no forwarding (take data directly from ID/EX)
        forwardAE = 2'b00;
        forwardBE = 2'b00;

        // ---------------------------------------------------------
        // Forward operand A (rs1E)
        // ---------------------------------------------------------

        // Forward from EX/MEM if that stage writes the same register
        if (RegWriteM && (rdM != 0) && (rdM == rs1E))
            forwardAE = 2'b10;

        // Otherwise forward from MEM/WB stage
        else if (RegWriteW && (rdW != 0) && (rdW == rs1E))
            forwardAE = 2'b01;

        // ---------------------------------------------------------
        // Forward operand B (rs2E)
        // ---------------------------------------------------------

        // Forward from EX/MEM
        if (RegWriteM && (rdM != 0) && (rdM == rs2E))
            forwardBE = 2'b10;

        // Otherwise from MEM/WB
        else if (RegWriteW && (rdW != 0) && (rdW == rs2E))
            forwardBE = 2'b01;
    end

endmodule
