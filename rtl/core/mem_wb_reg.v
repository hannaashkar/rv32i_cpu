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
    input        valid_in,        // real instruction — drives instret (D012)
    input [31:0] mem_data_in,     // MMIO/NPU read data (RAM read is now
                                  // registered inside dmem — B006/D016)
    input        mem_is_io_in,    // 1 = load targets IO/NPU, not RAM
    input [31:0] alu_result_in,   // ALU result for ALU instructions
    input [4:0]  rd_in,           // destination register
    input [31:0] pc_in,           // observability for lockstep co-sim

    // Outputs into WB stage
    output reg        RegWrite_out,
    output reg        MemToReg_out,
    output reg        valid_out,
    output reg [31:0] mem_data_out,
    output reg        mem_is_io_out,
    output reg [31:0] alu_result_out,
    output reg [4:0]  rd_out,
    output reg [31:0] pc_out
);

    // ---------------------------------------------------------
    // Pipeline storage: reset clears everything, normal
    // operation copies MEM signals into WB stage on each cycle.
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            RegWrite_out   <= 0;
            MemToReg_out   <= 0;
            valid_out      <= 0;
            mem_data_out   <= 0;
            mem_is_io_out  <= 0;
            alu_result_out <= 0;
            rd_out         <= 0;
            pc_out         <= 0;
        end else begin
            RegWrite_out   <= RegWrite_in;
            MemToReg_out   <= MemToReg_in;
            valid_out      <= valid_in;
            mem_data_out   <= mem_data_in;
            mem_is_io_out  <= mem_is_io_in;
            alu_result_out <= alu_result_in;
            rd_out         <= rd_in;
            pc_out         <= pc_in;
        end
    end

endmodule
