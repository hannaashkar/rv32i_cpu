// ============================================================================
// ooo_uop.vh — packed uop layout carried through the issue queue (D013)
// `include OUTSIDE the module so `UOPW can size ports.
// ============================================================================
`ifndef OOO_UOP_VH
`define OOO_UOP_VH

`define UOPW 162

// field slices
`define U_ALUCTRL   3:0     // alu_ops.vh code
`define U_ALUSRC    4       // operand B = imm
`define U_ALUAPC    5       // operand A = pc (AUIPC)
`define U_ISBR      6       // conditional branch
`define U_ISJALR    7
`define U_ISLOAD    8
`define U_ISSTORE   9
`define U_ISCSR     10
`define U_F3        13:11
`define U_IMM       45:14   // imm / branch TARGET / csr addr / pc+4 (JAL)
`define U_PC        77:46
`define U_PNPC      109:78  // pc the frontend followed after this uop
`define U_RS1A      114:110 // arch rs1 (csr zimm)
`define U_PS1       120:115
`define U_PS2       126:121
`define U_PD        132:127
`define U_WR        133
`define U_TAG       139:134 // ROB tag {phase, idx}
`define U_SQPOS     142:140 // store: own SQ slot
`define U_SQCOL     146:143 // load/store: 4b SQ tail identity at dispatch
`define U_CHK       150:147 // 4b checkpoint tag (branch/JALR)
`define U_HASCHK    151
`define U_GHR       161:152 // pre-shift GHR at fetch (train/restore)

`endif
