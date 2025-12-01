module mmio(
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    output reg  [31:0] rdata,

    output reg  [9:0]  leds,
    input  wire [9:0]  switches
);

    // ON RESET: turn off LEDs
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            leds <= 10'b0;
        end else begin
            // WRITE to LED address
            if (we && addr == 32'h40000000) begin
                leds <= wdata[9:0];
            end
        end
    end

    // READ logic
    always @(*) begin
        if (addr == 32'h40000000) begin
            rdata = {22'b0, leds};
        end else if (addr == 32'h40000004) begin
            rdata = {22'b0, switches};
        end else begin
            rdata = 32'b0;
        end
    end

endmodule
