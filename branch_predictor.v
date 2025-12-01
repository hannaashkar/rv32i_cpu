

// Simple 2-bit BHT + BTB branch predictor


module branch_predictor #(
    parameter INDEX_BITS = 6   // 64 entries
) (
    input  wire        clk,
    input  wire        reset,

    // === IF stage query ===
    input  wire [31:0] pcF,             // current fetch PC
    output wire [31:0] next_pc_predF,   // predicted next PC
    output wire        pred_takenF,     // predicted taken?
    output wire [31:0] pred_targetF,    // predicted target (or pc+4)

    // === EX stage update ===
    input  wire        BranchE,         // this instruction is a branch
    input  wire [31:0] pcE,             // PC of the branch in EX
    input  wire        branch_takenE,   // actual outcome
    input  wire [31:0] branch_targetE   // actual target
);

    localparam ENTRIES  = (1 << INDEX_BITS);
    localparam TAG_BITS = 32 - (INDEX_BITS + 2);

    // ---- BHT: 2-bit counters ----
    reg [1:0] bht [0:ENTRIES-1];

    // ---- BTB ----
    reg               btb_valid  [0:ENTRIES-1];
    reg [TAG_BITS-1:0]btb_tag    [0:ENTRIES-1];
    reg [31:0]        btb_target [0:ENTRIES-1];

    // Index & tag for IF
    wire [INDEX_BITS-1:0] indexF = pcF[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   tagF   = pcF[31:INDEX_BITS+2];

    // Index & tag for EX (update)
    wire [INDEX_BITS-1:0] indexE = pcE[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   tagE   = pcE[31:INDEX_BITS+2];

    // ------------------------------
    // Prediction (combinational)
    // ------------------------------
    wire [1:0] counterF = bht[indexF];
    assign pred_takenF  = counterF[1];          // MSB = prediction

    wire        btb_hitF   = btb_valid[indexF] && (btb_tag[indexF] == tagF);
    wire [31:0] seq_pcF    = pcF + 32'd4;

    assign pred_targetF  = (pred_takenF && btb_hitF) ? btb_target[indexF]
                                                    : seq_pcF;

    assign next_pc_predF = pred_targetF;

    // ------------------------------
    // Update logic (sequential)
    // ------------------------------
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // init BHT to weakly-not-taken (01), BTB invalid
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bht[i]       <= 2'b01;
                btb_valid[i] <= 1'b0;
                btb_tag[i]   <= {TAG_BITS{1'b0}};
                btb_target[i]<= 32'b0;
            end
        end else if (BranchE) begin
            // ---- BHT update (2-bit saturating counter) ----
            case ({branch_takenE, bht[indexE]})
                // taken: increment if not 11
                3'b1_00: bht[indexE] <= 2'b01;
                3'b1_01: bht[indexE] <= 2'b10;
                3'b1_10: bht[indexE] <= 2'b11;
                3'b1_11: bht[indexE] <= 2'b11;

                // not taken: decrement if not 00
                3'b0_00: bht[indexE] <= 2'b00;
                3'b0_01: bht[indexE] <= 2'b00;
                3'b0_10: bht[indexE] <= 2'b01;
                3'b0_11: bht[indexE] <= 2'b10;
            endcase

            // ---- BTB update on taken branches ----
            if (branch_takenE) begin
                btb_valid[indexE]  <= 1'b1;
                btb_tag[indexE]    <= tagE;
                btb_target[indexE] <= branch_targetE;
            end
            // (if not taken we leave BTB as is – BHT will move to "not taken")
        end
    end

endmodule
