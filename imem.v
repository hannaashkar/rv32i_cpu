module imem(
    input  wire [31:0] pc,
    output reg  [31:0] instruction
);

always @(*) begin
    case (pc[31:2])

        0: instruction = 32'h00100093;   // addi x1, x0, 1

        1: instruction = 32'h00400113;   // addi x2, x0, 4
        2: instruction = 32'h01C11113;   // slli x2, x2, 28   → x2 = 0x40000000

        3: instruction = 32'h001181B3;   // add x3, x3, x1
        4: instruction = 32'h00312023;   // sw x3, 0(x2)

        5: instruction = 32'hFE000AE3;   // beq x0, x0, -8

        default: instruction = 32'h00000013;
    endcase
end

endmodule
