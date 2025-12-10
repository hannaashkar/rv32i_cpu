module alu (
    input  wire [31:0] a,           // First operand (from rs1)
    input  wire [31:0] b,           // Second operand (rs2 or immediate value)
    input  wire [3:0]  alu_control, // Control signal that selects the ALU operation
    output reg  [31:0] result,      // Final ALU output
    output wire        zero         // Indicates if result equals zero (used by branch logic)
);

    always @(*) begin
        case (alu_control)
            4'b0000: result = a & b;                    // Bitwise AND
            4'b0001: result = a | b;                    // Bitwise OR
            4'b0010: result = a + b;                    // Standard ADD
            4'b0110: result = a - b;                    // Standard SUB
            4'b0111: result = ($signed(a) < $signed(b)) // Signed comparison for SLT
                             ? 32'd1 
                             : 32'd0;
            4'b1100: result = a ^ b;                    // Bitwise XOR
            default: result = 32'b0;                    // Default fallback for safety
        endcase
    end

    // zero flag used by the branch unit to check equality
    assign zero = (result == 32'b0);

endmodule
