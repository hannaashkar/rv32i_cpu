// ============================================================================
// ooo_pkg.vh — shared parameters for the 2-wide OoO core (decision D013)
// Include inside each ooo module. See docs/OOO.md for the binding spec.
// ============================================================================
localparam PHYS       = 64;               // physical registers (p0 == 0)
localparam PTAGW      = 6;                // log2(PHYS)
localparam ROBD       = 32;               // ROB entries
localparam ROBW       = 5;                // log2(ROBD)
localparam TAGW       = 6;                // ROB tag = {phase, idx}
localparam IQD        = 16;               // issue queue entries
localparam SQD        = 8;                // store queue entries
localparam SQW        = 3;                // log2(SQD)
localparam NCHKPT     = 8;                // rename checkpoints
localparam CHKW       = 3;                // log2(NCHKPT)
localparam GHRW       = 10;               // gshare history bits
localparam PHTD       = 1024;             // gshare PHT entries
localparam BTBD       = 64;               // BTB entries
localparam RASD       = 8;                // return-address stack depth

// uop port binding
localparam PORT_BR  = 2'd0;               // ALU + branch/JALR resolve
localparam PORT_ALU = 2'd1;               // ALU + CSR
localparam PORT_MEM = 2'd2;               // AGU + load/store
