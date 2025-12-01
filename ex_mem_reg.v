
module ex_mem_reg (
    input clk,
    input reset,

    // control
    input        RegWrite_in,
    input        MemToReg_in,
    input        MemRead_in,
    input        MemWrite_in,
    input        Branch_in,

    // data
    input [31:0] alu_result_in,
    input [31:0] rs2_data_in,   // store data
    input        zero_in,       // ALU zero flag (for branch)
    input [31:0] branch_target_in,
    input [4:0]  rd_in,

    // outputs
    output reg        RegWrite_out,
    output reg        MemToReg_out,
    output reg        MemRead_out,
    output reg        MemWrite_out,
    output reg        Branch_out,

    output reg [31:0] alu_result_out,
    output reg [31:0] rs2_data_out,
    output reg        zero_out,
    output reg [31:0] branch_target_out,
    output reg [4:0]  rd_out
);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        RegWrite_out     <= 0;
        MemToReg_out     <= 0;
        MemRead_out      <= 0;
        MemWrite_out     <= 0;
        Branch_out       <= 0;
        alu_result_out   <= 0;
        rs2_data_out     <= 0;
        zero_out         <= 0;
        branch_target_out<= 0;
        rd_out           <= 0;
    end else begin
        RegWrite_out     <= RegWrite_in;
        MemToReg_out     <= MemToReg_in;
        MemRead_out      <= MemRead_in;
        MemWrite_out     <= MemWrite_in;
        Branch_out       <= Branch_in;
        alu_result_out   <= alu_result_in;
        rs2_data_out     <= rs2_data_in;
        zero_out         <= zero_in;
        branch_target_out<= branch_target_in;
        rd_out           <= rd_in;
    end
end

endmodule
