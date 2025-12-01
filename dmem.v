

module dmem (
    input  wire        clk,
    input  wire        mem_read,      // control: read enable
    input  wire        mem_write,     // control: write enable
    input  wire [31:0] addr,          // address from ALU ~ alu result
    input  wire [31:0] write_data,    // from rs2_data
    output reg  [31:0] read_data      // output to write-back
);
    // 256 memory locations (word addressable)
    reg [31:0] memory [0:255];  // each cell is 32 bits, there are 256 cells in the memory array

    // Optional: initialize memory from file
    initial begin
        // $readmemh("data.mem", memory);
    end

    // Read = combinational (like instruction mem)
    always @(*) begin
        if (mem_read)
            read_data = memory[addr[31:2]]; // word-aligned
        else
            read_data = 32'b0;
    end

    // Write = synchronous
    always @(posedge clk) begin
        if (mem_write)
            memory[addr[31:2]] <= write_data; // store word
    end
	 
	 

endmodule
