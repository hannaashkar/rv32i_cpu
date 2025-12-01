module if_id_reg (
    input         clk,
    input         reset,
    input  [31:0] if_pc,
    input  [31:0] if_instruction,
    input         stall,   // usually comes from hazard unit: stallD
    input         flush,   // usually from branch/hazard: flushD
	 
	 input         pred_takenF,
    input  [31:0] pred_targetF,

    output reg [31:0] id_pc,
    output reg [31:0] id_instruction,
	 
	 output reg        pred_takenD,
    output reg [31:0] pred_targetD
);

always @(posedge clk or posedge reset) begin
    if (reset) begin
	 
        id_pc           <= 32'b0;
        id_instruction  <= 32'b0;
        pred_takenD  <= 1'b0;
        pred_targetD <= 32'b0;
		  
    end else if (flush) begin
        id_pc           <= 32'b0;
        id_instruction  <= 32'h00000013; // NOP
        pred_takenD  <= 1'b0;
        pred_targetD <= 32'b0;
		  
    end else if (!stall) begin
        id_pc           <= if_pc;
        id_instruction  <= if_instruction;
        pred_takenD <= pred_takenF;
        pred_targetD <= pred_targetF;
    end
end

endmodule
