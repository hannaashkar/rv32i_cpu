module if_id_reg (
    input         clk,
    input         reset,

    // Values produced in IF stage
    input  [31:0] if_pc,

    // Pipeline control signals
    input         stall,   // hold IF/ID (used for load-use hazards)
    input         flush,   // clear IF/ID (used for branch mispredict)

    // Branch predictor info (IF → ID)
    input         pred_takenF,
    input  [31:0] pred_targetF,

    // Outputs into ID stage
    output reg [31:0] id_pc,
    output reg        id_valid,   // architecturally real instruction (D012)

    // Predictor info latched into Decode stage
    output reg        pred_takenD,
    output reg [31:0] pred_targetD
);

    // ---------------------------------------------------------
    // IF/ID control register — pc, valid and predictor info.
    //
    // The instruction word itself no longer lives here: with synchronous
    // instruction memory (B006/D016) it rides imem's own read register and
    // arrives in Decode aligned with id_pc. id_valid is the squash signal —
    // cpu_pipeline forces the Decode instruction to a NOP whenever
    // id_valid=0 (reset startup, or a wrong-path fetch after a mispredict),
    // which is exactly what the old instruction flush→NOP path did.
    //
    // Handles: reset, flushing, and stalling.
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            id_pc        <= 32'b0;
            id_valid     <= 1'b0;
            pred_takenD  <= 1'b0;
            pred_targetD <= 32'b0;

        end else if (flush) begin
            // -------------------------------------------------
            // Flush IF/ID on a branch misprediction: mark the slot invalid
            // (valid=0). The Decode instruction is squashed to a NOP by the
            // valid mux in cpu_pipeline, so it retires nothing (instret,
            // D012) and has no architectural side effect.
            // -------------------------------------------------
            id_pc        <= 32'b0;
            id_valid     <= 1'b0;
            pred_takenD  <= 1'b0;
            pred_targetD <= 32'b0;

        end else if (!stall) begin
            // -------------------------------------------------
            // Normal pipeline advance: pass IF → ID. Stalling freezes the
            // current contents. Every instruction IF actually fetched is
            // architecturally real — wrong-path fetches die via flush above.
            // -------------------------------------------------
            id_pc        <= if_pc;
            id_valid     <= 1'b1;

            pred_takenD  <= pred_takenF;
            pred_targetD <= pred_targetF;
        end
    end

endmodule
