// src/mem_wb_reg.v
module mem_wb_reg (
    input clk,
    input reset,

    input        RegWrite_in,
    input        MemToReg_in,
    input [31:0] mem_data_in,
    input [31:0] alu_result_in,
    input [4:0]  rd_in,

    output reg        RegWrite_out,
    output reg        MemToReg_out,
    output reg [31:0] mem_data_out,
    output reg [31:0] alu_result_out,
    output reg [4:0]  rd_out
);

always @(posedge clk or posedge reset) begin
    if (reset) begin
        RegWrite_out   <= 0;
        MemToReg_out   <= 0;
        mem_data_out   <= 0;
        alu_result_out <= 0;
        rd_out         <= 0;
    end else begin
        RegWrite_out   <= RegWrite_in;
        MemToReg_out   <= MemToReg_in;
        mem_data_out   <= mem_data_in;
        alu_result_out <= alu_result_in;
        rd_out         <= rd_in;
    end
end

endmodule
