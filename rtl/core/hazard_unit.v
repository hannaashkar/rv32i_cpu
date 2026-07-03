module hazard_unit (
    input  wire       MemReadE,     // EX-stage instruction is a load
    input  wire [4:0] rdE,          // destination register of EX-stage instruction
    input  wire [4:0] rs1D,         // source register 1 in Decode
    input  wire [4:0] rs2D,         // source register 2 in Decode
    input  wire       mispredictE,  // branch misprediction detected in EX

    output reg        stallF,       // freeze PC update
    output reg        stallD,       // freeze IF/ID register
    output reg        flushE,       // turn ID/EX into a bubble
    output reg        if_id_flush   // flush IF/ID (bubble in Decode)
);

    // ---------------------------------------------------------
    // Load-use hazard detection:
    // A load in EX cannot forward its data in time for Decode.
    // If the next instruction depends on the loaded register,
    // we must stall the pipeline for one cycle.
    // ---------------------------------------------------------
    wire load_use_hazard;
    assign load_use_hazard =
        MemReadE &&
        (rdE != 5'b0) &&
        ((rdE == rs1D) || (rdE == rs2D));

    always @(*) begin
        // Default: pipeline runs without stalls or flushes
        stallF      = 1'b0;
        stallD      = 1'b0;
        flushE      = 1'b0;
        if_id_flush = 1'b0;

        // -----------------------------------------------------
        // Branch misprediction:
        // When EX discovers the prediction was wrong, we need:
        // - to flush the instruction currently in Decode
        // - to insert a bubble into Execute
        // -----------------------------------------------------
        if (mispredictE) begin
            if_id_flush = 1'b1;  // kill instruction in Decode (IF/ID)
            flushE      = 1'b1;  // bubble in Execute (ID/EX)
        end

        // -----------------------------------------------------
        // Load-use hazard:
        // When ID stage needs a value being loaded by EX,
        // forwarding is not possible → one-cycle stall.
        // -----------------------------------------------------
        if (load_use_hazard) begin
            stallF = 1'b1;   // freeze PC
            stallD = 1'b1;   // freeze IF/ID
            flushE = 1'b1;   // insert bubble into EX
        end
    end

endmodule
