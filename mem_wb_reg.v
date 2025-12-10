// -------------------------------------------------------------
// MEM/WB Pipeline Register
// -------------------------------------------------------------
// Captures memory-stage results and control signals, and passes
// them into the Writeback stage. This completes the pipeline path
// for load and ALU instructions.
// -------------------------------------------------------------

module mem_wb_reg (
    input clk,
    input reset,

    // Control & data coming from MEM stage
    input        RegWrite_in,
    input        MemToReg_in,
    input [31:0] mem_data_in,     // data read from memory (loads)
    input [31:0] alu_result_in,   // ALU result for ALU instructions
    input [4:0]  rd_in,           // destination register

    // Outputs into WB stage
    output reg        RegWrite_out,
    output reg        MemToReg_out,
    output reg [31:0] mem_data_out,
    output reg [31:0] alu_result_out,
    output reg [4:0]  rd_out
);

    // ---------------------------------------------------------
    // Pipeline storage: reset clears everything, normal
    // operation copies MEM signals into WB stage on each cycle.
    // ---------------------------------------------------------
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
