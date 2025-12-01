module hazard_unit (
    input  wire       MemReadE,
    input  wire [4:0] rdE,
    input  wire [4:0] rs1D,
    input  wire [4:0] rs2D,
    input  wire       mispredictE,  

    output reg        stallF,
    output reg        stallD,
    output reg        flushE,           // flush ID/EX (bubble in EX)
    output reg        if_id_flush       // flush IF/ID (bubble in ID)
);
    wire load_use_hazard;
    assign load_use_hazard = MemReadE &&
                             (rdE != 5'b0) &&
                             ((rdE == rs1D) || (rdE == rs2D));

    always @(*) begin
        // defaults
        stallF      = 1'b0;
        stallD      = 1'b0;
        flushE      = 1'b0;
        if_id_flush = 1'b0;

		  
		  
		  // 2) Branch taken in EX → flush IF/ID and ID/EX
        if (mispredictE) begin
            if_id_flush = 1'b1;  // kill instruction in Decode
            flushE      = 1'b1;  // bubble in Execute
        end
		  
		  
        // 1) Load-use hazard → stall F & D, flush E
        if (load_use_hazard) begin
            stallF = 1'b1;
            stallD = 1'b1;
            flushE = 1'b1;   // insert bubble into EX
        end

    end

endmodule
