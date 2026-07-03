// ============================================================================
// gshare_bp — gshare direction predictor + tagged BTB (2 lookup ports)
//
// Purpose:    Frontend prediction for the 2-wide OoO core (D013).
//             Direction: gshare (GHR xor pc) into a 2-bit PHT.
//             Target:    direct-tagged BTB storing target + is_cond.
// Interfaces: two same-cycle lookups (fetch slots pc, pc+4); one train
//             port (EX resolve for branches/JALR, decode for JAL); GHR
//             speculative shift at fetch, absolute restore on mispredict.
// Conventions:
//   * A slot predicts TAKEN only on BTB hit AND (uncond OR gshare says
//     taken). Unknown branches (BTB miss) fall through — the resolve
//     path trains them.
//   * The GHR the caller attaches to each fetched slot is the PRE-shift
//     value: the checkpoint restores it and shifts in the actual
//     outcome, so history stays exact across mispredicts.
// ============================================================================
module gshare_bp (
    input  wire        clk,
    input  wire        reset,

    // fetch-slot lookups (combinational)
    input  wire [31:0] pc0,
    input  wire [31:0] pc1,
    output wire        hit0,       // BTB hit
    output wire        cond0,      // entry is a conditional branch
    output wire        dir0,       // gshare direction for pc0
    output wire [31:0] target0,
    output wire        hit1,
    output wire        cond1,
    output wire        dir1,
    output wire [31:0] target1,

    // current speculative history (attached to fetched uops)
    output wire [9:0]  ghr_out,
    // speculative GHR shift: fetch asserts when a slot consumed a
    // conditional-branch prediction (shift in the predicted direction)
    input  wire        spec_shift,
    input  wire        spec_dir,
    // absolute GHR restore (mispredict recovery), then shift actual
    input  wire        restore_en,
    input  wire [9:0]  restore_ghr,
    input  wire        restore_shift,   // restored uop was conditional
    input  wire        restore_dir,     // its actual direction

    // train port (EX resolve; also decode-redirect for JAL)
    input  wire        train_en,
    input  wire [31:0] train_pc,
    input  wire        train_cond,      // conditional branch (vs JAL/JALR)
    input  wire        train_taken,
    input  wire [31:0] train_target,
    input  wire [9:0]  train_ghr        // pre-shift GHR at that fetch
);

`include "ooo_pkg.vh"

    // ------------------------------------------------------------ BTB
    reg [31:0] btb_target [0:BTBD-1];
    reg [23:0] btb_tag    [0:BTBD-1];   // pc[31:8]
    reg        btb_valid  [0:BTBD-1];
    reg        btb_cond   [0:BTBD-1];

    wire [5:0]  idx0 = pc0[7:2];
    wire [5:0]  idx1 = pc1[7:2];
    assign hit0    = btb_valid[idx0] && (btb_tag[idx0] == pc0[31:8]);
    assign target0 = btb_target[idx0];
    assign cond0   = btb_cond[idx0];
    assign hit1    = btb_valid[idx1] && (btb_tag[idx1] == pc1[31:8]);
    assign target1 = btb_target[idx1];
    assign cond1   = btb_cond[idx1];

    // ------------------------------------------------------------ gshare
    reg [1:0] pht [0:PHTD-1];
    reg [9:0] ghr;
    assign ghr_out = ghr;

    wire [9:0] pidx0 = pc0[11:2] ^ ghr;
    wire [9:0] pidx1 = pc1[11:2] ^ ghr;
    assign dir0 = pht[pidx0][1];
    assign dir1 = pht[pidx1][1];

    wire [9:0] tidx = train_pc[11:2] ^ train_ghr;

    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ghr <= 10'b0;
            for (i = 0; i < BTBD; i = i + 1) btb_valid[i] <= 1'b0;
            for (i = 0; i < PHTD; i = i + 1) pht[i] <= 2'b01; // weak NT
        end else begin
            // GHR: restore beats speculative shift
            if (restore_en)
                ghr <= restore_shift ? {restore_ghr[8:0], restore_dir}
                                     : restore_ghr;
            else if (spec_shift)
                ghr <= {ghr[8:0], spec_dir};

            if (train_en) begin
                // BTB learns every taken control-flow instruction
                if (train_taken) begin
                    btb_valid [train_pc[7:2]] <= 1'b1;
                    btb_tag   [train_pc[7:2]] <= train_pc[31:8];
                    btb_target[train_pc[7:2]] <= train_target;
                    btb_cond  [train_pc[7:2]] <= train_cond;
                end
                // PHT trains only on conditional branches
                if (train_cond) begin
                    if (train_taken  && pht[tidx] != 2'b11)
                        pht[tidx] <= pht[tidx] + 2'b01;
                    if (!train_taken && pht[tidx] != 2'b00)
                        pht[tidx] <= pht[tidx] - 2'b01;
                end
            end
        end
    end

endmodule
