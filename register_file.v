
module register_file (
    input  wire        clk,
    input  wire        reset,

    // Write port for writeback
    input  wire        reg_write,      // 1 = write enabled
    input  wire [4:0]  rd_addr,        // which register number to write to (destination).
    input  wire [31:0] rd_data,        // data to be written

    // Read port 1 for alu
    input  wire [4:0]  rs1_addr,       // source register 1 index
    output wire [31:0] rs1_data,       // data from register rs1

    // Read port 2 for alu
    input  wire [4:0]  rs2_addr,       // source register 2 index
    output wire [31:0] rs2_data        // data from register rs2
);

    // array of 32 general purpose registers each is 32 bits.
    reg [31:0] regs [31:0];

    integer i;

    // Optional: reset all registers to 0 (except x0 which is always 0 anyway)
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                regs[i] <= 32'b0;
            end
        end else begin
            // Write on rising clock edge if enabled AND rd_addr != 0
            if (reg_write && (rd_addr != 5'd0)) begin
                regs[rd_addr] <= rd_data;
            end
        end
    end

    // Read ports are combinational.
    // Register 0 is hard-wired to 0.
    assign rs1_data = (rs1_addr == 5'd0) ? 32'b0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'b0 : regs[rs2_addr];

endmodule
