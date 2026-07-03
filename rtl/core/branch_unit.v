// ============================================================================
// branch_unit — dedicated branch condition evaluation (decision D007/B2)
//
// Purpose:    Decides taken/not-taken for all six RV32I conditional
//             branches, directly from the forwarded operands. Keeping this
//             out of the ALU shortens the EX branch-resolve path (which
//             feeds the mispredict redirect — the critical path) and gives
//             the future OoO core its standalone branch unit.
// Interfaces: a, b = forwarded rs1/rs2; funct3 selects the condition;
//             taken is only meaningful when the instruction is a branch
//             (gated by BranchE in cpu_pipeline).
// Assumptions:
//   * funct3 010/011 are not branch encodings — they resolve not-taken.
//     Illegal-instruction detection arrives with traps, later.
// ============================================================================
module branch_unit (
    input  wire [31:0] a,       // rs1 (forwarded)
    input  wire [31:0] b,       // rs2 (forwarded)
    input  wire [2:0]  funct3,  // condition select
    output reg         taken
);

    wire eq  = (a == b);
    wire lt  = ($signed(a) < $signed(b));
    wire ltu = (a < b);

    always @(*) begin
        case (funct3)
            3'b000: taken = eq;      // BEQ
            3'b001: taken = ~eq;     // BNE
            3'b100: taken = lt;      // BLT  (signed)
            3'b101: taken = ~lt;     // BGE  (signed)
            3'b110: taken = ltu;     // BLTU (unsigned)
            3'b111: taken = ~ltu;    // BGEU (unsigned)
            default: taken = 1'b0;   // 010/011: not branch encodings
        endcase
    end

endmodule
