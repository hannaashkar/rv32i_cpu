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
localparam [1:0] ALUCLASS_ADD    = 2'b00; // loads/stores: address add
localparam [1:0] ALUCLASS_SUB    = 2'b01; // branches: compare (until B2)
localparam [1:0] ALUCLASS_RTYPE  = 2'b10; // decode funct3 + instr[30]
localparam [1:0] ALUCLASS_ITYPE  = 2'b11; // decode funct3; instr[30] only
                                          // for shift-right (SRLI/SRAI)
