// Local branch predictor using a 2-bit BHT plus a small BTB

module branch_predictor #(
    parameter INDEX_BITS = 6   // Number of index bits → 2^INDEX_BITS entries
) (
    input  wire        clk,
    input  wire        reset,

    // === IF stage query ===
    input  wire [31:0] pcF,             // PC of the instruction currently in fetch
    output wire [31:0] next_pc_predF,   // Predicted next PC for the fetch stage
    output wire        pred_takenF,     // Predicted branch direction (1 = taken)
    output wire [31:0] pred_targetF,    // Predicted target (or pc+4 for not taken)

    // === EX stage update ===
    input  wire        BranchE,         // Asserted if the EX-stage instruction is a branch
    input  wire [31:0] pcE,             // PC of the branch currently in EX
    input  wire        branch_takenE,   // Actual outcome from the EX stage
    input  wire [31:0] branch_targetE   // Actual computed branch target
);

    localparam ENTRIES  = (1 << INDEX_BITS);
    localparam TAG_BITS = 32 - (INDEX_BITS + 2);

    // 2-bit Branch History Table (BHT): stores saturating counters per entry
    reg [1:0] bht [0:ENTRIES-1];

    // Branch Target Buffer (BTB): holds valid bit, tag, and target address
    reg                btb_valid  [0:ENTRIES-1];
    reg [TAG_BITS-1:0] btb_tag    [0:ENTRIES-1];
    reg [31:0]         btb_target [0:ENTRIES-1];

    // Index and tag for the fetch stage (IF)
    wire [INDEX_BITS-1:0] indexF = pcF[INDEX_BITS+1:2];       // Drop low 2 bits (word aligned)
    wire [TAG_BITS-1:0]   tagF   = pcF[31:INDEX_BITS+2];      // Upper bits form the tag

    // Index and tag for the execute stage (EX) when we update the predictor
    wire [INDEX_BITS-1:0] indexE = pcE[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   tagE   = pcE[31:INDEX_BITS+2];

    // ------------------------------
    // Prediction path (combinational)
    // ------------------------------
    wire [1:0] counterF = bht[indexF];          // Read 2-bit counter for this PC index
    assign pred_takenF  = counterF[1];          // MSB acts as the taken/not-taken prediction

    wire        btb_hitF = btb_valid[indexF] && (btb_tag[indexF] == tagF);
    wire [31:0] seq_pcF  = pcF + 32'd4;         // Fall-through address (next sequential PC)

    // If we predict taken and BTB has a matching entry, use the stored target.
    // Otherwise, just go to the next sequential PC.
    assign pred_targetF  = (pred_takenF && btb_hitF) ? btb_target[indexF]
                                                     : seq_pcF;

    assign next_pc_predF = pred_targetF;

    // ------------------------------
    // Update path (sequential)
    // ------------------------------
    integer i;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // Initialize BHT to weakly-not-taken (01) and clear BTB entries
            for (i = 0; i < ENTRIES; i = i + 1) begin
                bht[i]        <= 2'b01;
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= {TAG_BITS{1'b0}};
                btb_target[i] <= 32'b0;
            end
        end else if (BranchE) begin
            // ---- Update BHT: 2-bit saturating counter per branch ----
            case ({branch_takenE, bht[indexE]})
                // Outcome = taken (1), move counter towards strongly taken
                3'b1_00: bht[indexE] <= 2'b01;
                3'b1_01: bht[indexE] <= 2'b10;
                3'b1_10: bht[indexE] <= 2'b11;
                3'b1_11: bht[indexE] <= 2'b11;

                // Outcome = not taken (0), move counter towards strongly not taken
                3'b0_00: bht[indexE] <= 2'b00;
                3'b0_01: bht[indexE] <= 2'b00;
                3'b0_10: bht[indexE] <= 2'b01;
                3'b0_11: bht[indexE] <= 2'b10;
            endcase

            // ---- Update BTB only when the branch is actually taken ----
            if (branch_takenE) begin
                btb_valid[indexE]  <= 1'b1;
                btb_tag[indexE]    <= tagE;
                btb_target[indexE] <= branch_targetE;
            end
            // If the branch is not taken, we leave BTB as-is and let the BHT drift to not-taken.
        end
    end

endmodule
