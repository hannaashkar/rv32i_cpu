// forwarding_unit.v
// 2-bit forwarding controls for ALU operands in EX stage
// 00 = use value from ID/EX register
// 10 = forward from EX/MEM stage (alu_resultM)
// 01 = forward from MEM/WB stage (resultW)

module forwarding_unit (
    input  wire [4:0] rs1E,
    input  wire [4:0] rs2E,
    input  wire [4:0] rdM,
    input  wire [4:0] rdW,
    input  wire       RegWriteM,
    input  wire       RegWriteW,

    output reg  [1:0] forwardAE,
    output reg  [1:0] forwardBE
);

always @(*) begin
    // defaults
    forwardAE = 2'b00;
    forwardBE = 2'b00;

    // ---- Forward A (rs1) ----
    // from MEM stage
    if (RegWriteM && (rdM != 0) && (rdM == rs1E))
        forwardAE = 2'b10;
    // from WB stage
    else if (RegWriteW && (rdW != 0) && (rdW == rs1E))
        forwardAE = 2'b01;

    // ---- Forward B (rs2) ----
    // from MEM stage
    if (RegWriteM && (rdM != 0) && (rdM == rs2E))
        forwardBE = 2'b10;
    // from WB stage
    else if (RegWriteW && (rdW != 0) && (rdW == rs2E))
        forwardBE = 2'b01;
end

endmodule
