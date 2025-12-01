module de10_top (
    input  wire        CLOCK_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR
);

    reg reset_sync = 1;
	 
		always @(posedge CLOCK_50) begin
			 reset_sync <= ~KEY[0];  // one-cycle sync
		end

		wire reset = reset_sync;


    // Clock divider so we can see LED changes from CPU
    reg [31:0] div = 0;
    always @(posedge CLOCK_50)
        div <= div + 1;

     wire cpu_clk = div[25];
	  


    // CPU instance drives LEDR directly
    cpu_pipeline CPU0 (
        .clk      (cpu_clk),
        .reset    (reset),
        .leds     (LEDR),    // IMPORTANT: LEDs now come from CPU
        .switches (SW)
    );

endmodule
