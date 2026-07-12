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
localparam LQD        = 8;                // load queue entries (D020)
localparam LQW        = 3;                // log2(LQD)
localparam NCHKPT     = 8;                // rename checkpoints
localparam CHKW       = 3;                // log2(NCHKPT)
localparam GHRW       = 10;               // gshare history bits
// PHTD is the logical gshare PHT size. Since D024 the synthesizable PHT
// geometry is HARDCODED in gshare_bp.v (two 512x2 M9K banks, 10-bit
// index, DEPTH=512 in synth/pht_init.mif) — resizing the real predictor
// means editing gshare_bp.v + the MIF together, NOT this constant. PHTD
// drives only the INV-G2 simulation shadow; keep it equal to the real
// 2*512 = 1024 or that self-check mis-sizes. GHRW likewise documents the
// 10-bit GHR that gshare_bp declares directly.
localparam PHTD       = 1024;             // gshare PHT entries (see note)
localparam BTBD       = 64;               // BTB entries
localparam RASD       = 8;                // return-address stack depth

// uop port binding
localparam PORT_BR  = 2'd0;               // ALU + branch/JALR resolve
localparam PORT_ALU = 2'd1;               // ALU + CSR
localparam PORT_MEM = 2'd2;               // AGU + load/store
