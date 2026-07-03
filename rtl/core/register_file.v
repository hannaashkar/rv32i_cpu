module register_file (
    input  wire        clk,
    input  wire        reset,

    // Write port (from Writeback stage)
    input  wire        reg_write,      // write enable signal
    input  wire [4:0]  rd_addr,        // destination register index
    input  wire [31:0] rd_data,        // data to write into rd

    // Read port 1 (used by ALU operand A)
    input  wire [4:0]  rs1_addr,       // source register 1 index
    output wire [31:0] rs1_data,       // register contents for rs1

    // Read port 2 (used by ALU operand B)
    input  wire [4:0]  rs2_addr,       // source register 2 index
    output wire [31:0] rs2_data        // register contents for rs2
);

    // ---------------------------------------------------------
    // Register File: 32 registers × 32 bits
    // ---------------------------------------------------------
    reg [31:0] regs [31:0];
    integer i;

    // ---------------------------------------------------------
    // Synchronous write + optional reset
    // ---------------------------------------------------------
    // On reset: clear all registers (x0 is always hard-wired to 0 anyway).
    // On normal operation:
    //   - write occurs only on rising clock edge
    //   - rd_addr == 0 is ignored since x0 must remain 0
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                regs[i] <= 32'b0;
            end
        end else begin
            if (reg_write && (rd_addr != 5'd0)) begin
                regs[rd_addr] <= rd_data;
            end
        end
    end

    // ---------------------------------------------------------
    // Combinational read ports with internal write->read bypass
    // ---------------------------------------------------------
    // Register x0 is constant zero by RISC-V spec.
    //
    // Bypass ("write-first" behavior): a register being written back this
    // cycle must be visible to the instruction reading in ID in the same
    // cycle. The EX forwarding unit only covers producers still in MEM/WB;
    // a producer exactly 3 instructions ahead is *leaving* WB while the
    // consumer reads in ID, so without this bypass the consumer gets the
    // stale array value (BUGLOG B008).
    // ---------------------------------------------------------
    wire bypass_rs1 = reg_write && (rd_addr != 5'd0) && (rd_addr == rs1_addr);
    wire bypass_rs2 = reg_write && (rd_addr != 5'd0) && (rd_addr == rs2_addr);

    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 :
                      bypass_rs1         ? rd_data : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 :
                      bypass_rs2         ? rd_data : regs[rs2_addr];

endmodule
