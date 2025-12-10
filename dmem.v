module dmem (
    input  wire        clk,
    input  wire        mem_read,      // read enable from control unit
    input  wire        mem_write,     // write enable from control unit
    input  wire [31:0] addr,          // byte address from the ALU (word-aligned)
    input  wire [31:0] write_data,    // data to store (usually rs2)
    output reg  [31:0] read_data      // output data back into pipeline
);

    // ------------------------------------------------------
    // Simple data memory:
    // 256 words of 32-bit storage (total 1 KB)
    // Accessed via word-aligned addresses (addr[31:2])
    // ------------------------------------------------------
    reg [31:0] memory [0:255];

    // ------------------------------------------------------
    // Optional memory initialization for simulations
    // ------------------------------------------------------
    initial begin
        // $readmemh("data.mem", memory);  
        // Uncomment to preload memory from a hex file
    end

    // ------------------------------------------------------
    // Read logic (combinational)
    // Reads happen immediately without waiting for clock edge
    // ------------------------------------------------------
    always @(*) begin
        if (mem_read)
            read_data = memory[addr[31:2]];   // use word index
        else
            read_data = 32'b0;                // default when not reading
    end

    // ------------------------------------------------------
    // Write logic (synchronous)
    // Writes commit on the rising edge of the clock
    // ------------------------------------------------------
    always @(posedge clk) begin
        if (mem_write)
            memory[addr[31:2]] <= write_data;
    end

endmodule
