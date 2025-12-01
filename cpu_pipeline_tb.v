module cpu_pipeline_tb;

    reg clk = 0;
    reg reset = 1;

    // Instantiate your top-level pipelined CPU
    cpu_pipeline dut (
        .clk(clk),
        .reset(reset),
		  .leds(),          // leave unconnected but declared
         .switches(10'b0)  // switches = 0
    );

    // Clock generation: 10ns period
    always #5 clk = ~clk;

    initial begin
        // Hold reset for a short time
        #20;
        reset = 0;

        // Run the CPU for some cycles
        #300;
        $stop;
    end

endmodule
