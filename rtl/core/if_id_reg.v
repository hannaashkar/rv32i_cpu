module if_id_reg (
    input         clk,
    input         reset,

    // Values produced in IF stage
    input  [31:0] if_pc,
    input  [31:0] if_instruction,

    // Pipeline control signals
    input         stall,   // hold IF/ID (used for load-use hazards)
    input         flush,   // clear IF/ID (used for branch mispredict)

    // Branch predictor info (IF → ID)
    input         pred_takenF,
    input  [31:0] pred_targetF,

    // Outputs into ID stage
    output reg [31:0] id_pc,
    output reg [31:0] id_instruction,

    // Predictor info latched into Decode stage
    output reg        pred_takenD,
    output reg [31:0] pred_targetD
);

    // ---------------------------------------------------------
    // IF/ID pipeline register
    // Handles: reset, flushing, and stalling
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            // Clear pipeline register on reset
            id_pc          <= 32'b0;
            id_instruction <= 32'b0;
            pred_takenD    <= 1'b0;
            pred_targetD   <= 32'b0;

        end else if (flush) begin
            // -------------------------------------------------
            // Flush IF/ID when a branch misprediction occurs
            // Insert a NOP into Decode (ADDI x0, x0, 0 = 0x13)
            // -------------------------------------------------
            id_pc          <= 32'b0;
            id_instruction <= 32'h00000013;   // RISC-V NOP
            pred_takenD    <= 1'b0;
            pred_targetD   <= 32'b0;

        end else if (!stall) begin
            // -------------------------------------------------
            // Normal pipeline advance: pass IF → ID
            // Stalling freezes the current contents
            // -------------------------------------------------
            id_pc          <= if_pc;
            id_instruction <= if_instruction;

            pred_takenD    <= pred_takenF;
            pred_targetD   <= pred_targetF;
        end
    end

endmodule
