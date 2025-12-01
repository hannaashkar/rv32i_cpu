


module sign_extend (                   // according to instruction type
    input  wire [31:0] instruction,
    output reg  [31:0] imm_ext
);
    wire [6:0] opcode = instruction[6:0];

    always @(*) begin
        case (opcode)
            7'b0010011,          // I-type ALU (ADDI, ANDI, ORI, etc.)
            7'b0000011: begin    // I-type load (LW)
                // imm[31:20]
                imm_ext = {{20{instruction[31]}}, instruction[31:20]};
            end

            7'b0100011: begin    // S-type store (SW)
                // imm[31:25 | 11:7]
                imm_ext = {{20{instruction[31]}},
                           instruction[31:25],
                           instruction[11:7]};
            end

            7'b1100011: begin    // B-type branch (BEQ, BNE)
                // imm[12|10:5|4:1|11|0] from [31|30:25|11:8|7]
                imm_ext = {{19{instruction[31]}},
                           instruction[31],
                           instruction[7],
                           instruction[30:25],
                           instruction[11:8],
                           1'b0};   // low bit is 0 (word aligned)
            end

            default: begin
                imm_ext = 32'b0;
            end
        endcase
    end
endmodule
