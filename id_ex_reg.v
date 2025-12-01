module id_ex_reg (
    input clk,
    input reset,

    // NEW: flush signal from hazard / branch logic
    input flush,

    // control from ID
    input        RegWrite_in,
    input        MemRead_in,
    input        MemWrite_in,
    input        MemToReg_in,
    input        ALUSrc_in,
    input        Branch_in,
    input  [1:0] ALUOp_in,

    // data / fields from ID
    input [31:0] pc_in,
    input [31:0] rs1_data_in,
    input [31:0] rs2_data_in,
    input [31:0] imm_in,
    input [4:0]  rs1_in,
    input [4:0]  rs2_in,
    input [4:0]  rd_in,
    input [2:0]  funct3_in,
    input [6:0]  funct7_in,
	 
	 input         pred_takenD,
    input  [31:0] pred_targetD,

    // outputs to EX
    output reg        RegWrite_out,
    output reg        MemRead_out,
    output reg        MemWrite_out,
    output reg        MemToReg_out,
    output reg        ALUSrc_out,
    output reg        Branch_out,
    output reg [1:0]  ALUOp_out,

    output reg [31:0] pc_out,
    output reg [31:0] rs1_data_out,
    output reg [31:0] rs2_data_out,
    output reg [31:0] imm_out,
    output reg [4:0]  rs1_out,
    output reg [4:0]  rs2_out,
    output reg [4:0]  rd_out,
    output reg [2:0]  funct3_out,
    output reg [6:0]  funct7_out,
	 
	 output reg    pred_takenE,
    output reg [31:0] pred_targetE
);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        // async reset: clear everything
        RegWrite_out <= 0;
        MemRead_out  <= 0;
        MemWrite_out <= 0;
        MemToReg_out <= 0;
        ALUSrc_out   <= 0;
        Branch_out   <= 0;
        ALUOp_out    <= 0;

        pc_out       <= 0;
        rs1_data_out <= 0;
        rs2_data_out <= 0;
        imm_out      <= 0;
        rs1_out      <= 0;
        rs2_out      <= 0;
        rd_out       <= 0;
        funct3_out   <= 0;
        funct7_out   <= 0;
		  pred_takenE <=0;
		  pred_targetE <=0;
		  
    end else if (flush) begin
        // sync flush: insert bubble into EX
        RegWrite_out <= 0;
        MemRead_out  <= 0;
        MemWrite_out <= 0;
        MemToReg_out <= 0;
        ALUSrc_out   <= 0;
        Branch_out   <= 0;
        ALUOp_out    <= 0;
		  
		  pred_takenE <=0;
		  pred_takenE <=0;

        pc_out       <= 0;
        rs1_data_out <= 0;
        rs2_data_out <= 0;
        imm_out      <= 0;
        rs1_out      <= 0;
        rs2_out      <= 0;
        rd_out       <= 0;
        funct3_out   <= 0;
        funct7_out   <= 0;
    end else begin
        // normal pipeline advance
        RegWrite_out <= RegWrite_in;
        MemRead_out  <= MemRead_in;
        MemWrite_out <= MemWrite_in;
        MemToReg_out <= MemToReg_in;
        ALUSrc_out   <= ALUSrc_in;
        Branch_out   <= Branch_in;
        ALUOp_out    <= ALUOp_in;

        pc_out       <= pc_in;
        rs1_data_out <= rs1_data_in;
        rs2_data_out <= rs2_data_in;
        imm_out      <= imm_in;
        rs1_out      <= rs1_in;
        rs2_out      <= rs2_in;
        rd_out       <= rd_in;
        funct3_out   <= funct3_in;
        funct7_out   <= funct7_in;
		  
		  pred_takenE <= pred_takenD;
		  pred_targetE <= pred_targetD; 
    end
end

endmodule
