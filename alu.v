

module alu (
    input  wire [31:0] a,           // first operand (usually rs1_data)
    input  wire [31:0] b,           // second operand (rs2_data or immediate)
    input  wire [3:0]  alu_control, // selects the operation
    output reg  [31:0] result,      // ALU result
    output wire        zero         // 1 if result == 0
);

    always @(*) begin
        case (alu_control)
            4'b0000: result = a & b;                     // AND
            4'b0001: result = a | b;                     // OR
            4'b0010: result = a + b;                     // ADD
            4'b0110: result = a - b;                     // SUB
            4'b0111: result = ($signed(a) < $signed(b))  // SLT (signed)
                             ? 32'd1 
                             : 32'd0;
            4'b1100: result = a ^ b;                     // XOR
            default: result = 32'b0;                     // default
        endcase
    end

    // zero flag is high when result is 0
    assign zero = (result == 32'b0);

endmodule
