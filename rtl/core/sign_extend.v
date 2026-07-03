module sign_extend (
    input  wire [31:0] instruction,   // full instruction from Decode stage
    output reg  [31:0] imm_ext        // sign-extended immediate
);

    // Extract opcode to determine immediate format
    wire [6:0] opcode = instruction[6:0];

    always @(*) begin
        case (opcode)

            // -------------------------------------------------
            // I-type immediate (ADDI, ANDI, ORI, LW, etc.)
            // imm[31:20] → sign-extended to 32 bits
            // -------------------------------------------------
            7'b0010011,          // I-type ALU
            7'b0000011,          // I-type load (LW)
            7'b1100111: begin    // JALR (I-type offset)
                imm_ext = {{20{instruction[31]}}, instruction[31:20]};
            end

            // -------------------------------------------------
            // J-type immediate (JAL)
            // imm[20|10:1|11|19:12] scattered as:
            // instr[31] | instr[19:12] | instr[20] | instr[30:21] | 0
            // -------------------------------------------------
            7'b1101111: begin    // JAL
                imm_ext = {{11{instruction[31]}},
                           instruction[31],
                           instruction[19:12],
                           instruction[20],
                           instruction[30:21],
                           1'b0};
            end

            // -------------------------------------------------
            // S-type immediate (store instructions: SW)
            // imm = {instr[31:25], instr[11:7]}
            // -------------------------------------------------
            7'b0100011: begin    // S-type store
                imm_ext = {{20{instruction[31]}},
                           instruction[31:25],
                           instruction[11:7]};
            end

            // -------------------------------------------------
            // B-type immediate (branches: BEQ, BNE)
            // The immediate bits are scattered across fields:
            // imm[12]   = instr[31]
            // imm[11]   = instr[7]
            // imm[10:5] = instr[30:25]
            // imm[4:1]  = instr[11:8]
            // imm[0]    = 0   (branches are 2-byte aligned)
            // -------------------------------------------------
            7'b1100011: begin   // B-type branch
                imm_ext = {{19{instruction[31]}},    // sign extension
                           instruction[31],           // imm[12]
                           instruction[7],            // imm[11]
                           instruction[30:25],        // imm[10:5]
                           instruction[11:8],         // imm[4:1]
                           1'b0};                     // imm[0]
            end

            // -------------------------------------------------
            // U-type immediate (LUI, AUIPC)
            // imm = {instr[31:12], 12'b0} — no sign extension needed,
            // bit 31 lands in the result's bit 31 directly
            // -------------------------------------------------
            7'b0110111,          // LUI
            7'b0010111: begin    // AUIPC
                imm_ext = {instruction[31:12], 12'b0};
            end

            // -------------------------------------------------
            // Unsupported opcodes → default to 0
            // -------------------------------------------------
            default: begin
                imm_ext = 32'b0;
            end
        endcase
    end

endmodule
