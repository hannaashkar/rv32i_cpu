module imem(
    input  wire [31:0] pc,           // byte address coming from Fetch stage
    output reg  [31:0] instruction   // fetched instruction
);

    // ---------------------------------------------------------
    // Simple instruction memory using a case statement.
    // Access is word-aligned using pc[31:2].
    // ---------------------------------------------------------
    always @(*) begin
        case (pc[31:2])

            // Program stored directly in logic (for FPGA demo)
            0: instruction = 32'h00100093;   // addi x1, x0, 1

            1: instruction = 32'h00400113;   // addi x2, x0, 4
            2: instruction = 32'h01C11113;   // slli x2, x2, 28 → x2 = 0x40000000

            3: instruction = 32'h001181B3;   // add x3, x3, x1
            4: instruction = 32'h00312023;   // sw x3, 0(x2)

            5: instruction = 32'hFE000AE3;   // beq x0, x0, -8 (infinite loop)

            // Default → NOP (ADDI x0, x0, 0)
            default: instruction = 32'h00000013;
        endcase
    end

endmodule
