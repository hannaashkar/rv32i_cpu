// ============================================================================
// alu_ops.vh — shared ALU operation encoding (decision D006/A2)
//
// Included by alu.v (executes) and alu_control.v (decodes) so the encoding
// can never drift between them.
// ============================================================================
localparam [3:0] ALU_ADD    = 4'd0;
localparam [3:0] ALU_SUB    = 4'd1;
localparam [3:0] ALU_AND    = 4'd2;
localparam [3:0] ALU_OR     = 4'd3;
localparam [3:0] ALU_XOR    = 4'd4;
localparam [3:0] ALU_SLT    = 4'd5;   // signed set-less-than
localparam [3:0] ALU_SLTU   = 4'd6;   // unsigned set-less-than
localparam [3:0] ALU_SLL    = 4'd7;   // shift left logical
localparam [3:0] ALU_SRL    = 4'd8;   // shift right logical
localparam [3:0] ALU_SRA    = 4'd9;   // shift right arithmetic
localparam [3:0] ALU_PASS_B = 4'd10;  // result = b (LUI, decision D009)

// Operation-class encoding produced by control.v (replaces textbook ALUOp):
localparam [2:0] ALUCLASS_ADD    = 3'b000; // loads/stores/AUIPC/JALR: add
localparam [2:0] ALUCLASS_SUB    = 3'b001; // legacy compare class (unused
                                           // since branch_unit, D007/B2)
localparam [2:0] ALUCLASS_RTYPE  = 3'b010; // decode funct3 + instr[30]
localparam [2:0] ALUCLASS_ITYPE  = 3'b011; // decode funct3; instr[30] only
                                           // for shift-right (SRLI/SRAI)
localparam [2:0] ALUCLASS_PASSB  = 3'b100; // LUI: result = immediate
