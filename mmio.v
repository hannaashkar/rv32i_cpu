module mmio(
    input  wire        clk,
    input  wire        reset,

    // Address and data signals from MEM stage
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,        // write-enable (from store instruction)

    output reg  [31:0] rdata,     // read-back data into the CPU

    // Physical FPGA hardware
    output reg  [9:0]  leds,      // LED register (writeable)
    input  wire [9:0]  switches   // Switch register (read-only)
);

    // ---------------------------------------------------------
    // LED Register (Memory-Mapped Output)
    // ---------------------------------------------------------
    // On reset → clear LEDs.
    // On write → if the CPU writes to address 0x4000_0000,
    // update the bottom 10 bits of the LED register.
    // ---------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            leds <= 10'b0;
        end else begin
            if (we && addr == 32'h40000000) begin
                leds <= wdata[9:0];
            end
        end
    end

    // ---------------------------------------------------------
    // Memory-Mapped Read Logic (Combinational)
    // ---------------------------------------------------------
    // 0x4000_0000 → read LED register
    // 0x4000_0004 → read switch values
    // Anything else → return zero
    // ---------------------------------------------------------
    always @(*) begin
        if (addr == 32'h40000000) begin
            rdata = {22'b0, leds};        // zero-extend LED bits
        end else if (addr == 32'h40000004) begin
            rdata = {22'b0, switches};    // zero-extend switch bits
        end else begin
            rdata = 32'b0;                // unmapped address
        end
    end

endmodule
