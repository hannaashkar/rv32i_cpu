module cpu_pipeline_tb;

    // Basic clock and reset setup
    reg clk   = 0;
    reg reset = 1;

    // Instantiate the full pipelined CPU
    cpu_pipeline dut (
        .clk      (clk),
        .reset    (reset),
        .leds     (),          // not used in simulation
        .switches (10'b0)      // keep switches tied to zero
    );

    // Clock generator: 10 ns period (100 MHz in simulation)
    always #5 clk = ~clk;

    initial begin
        // Apply reset for a short time to initialize the pipeline
        #20;
        reset = 0;

        // Let the CPU run a few hundred cycles
        #300;
        $stop;
    end

endmodule
