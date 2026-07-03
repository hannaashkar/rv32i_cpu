module de10_top (
    input  wire        CLOCK_50,   // 50 MHz base clock from the DE10 board
    input  wire [1:0]  KEY,        // push buttons (KEY[0] used as reset)
    input  wire [9:0]  SW,         // switches routed to the CPU
    output wire [9:0]  LEDR        // LEDs driven by the CPU via MMIO
);

    // ======================================================
    // Reset Synchronization
    // ======================================================
    // KEY[0] is active-low on the DE10 board.
    // Here we synchronize it to the system clock to avoid metastability.
    reg reset_sync = 1;

    always @(posedge CLOCK_50) begin
        reset_sync <= ~KEY[0];   // convert active-low pushbutton to active-high reset
    end

    wire reset = reset_sync;

    // ======================================================
    // Clock Divider
    // ======================================================
    // The CPU normally runs too fast to see LED updates by eye.
    // This divider lowers the frequency so LED output becomes observable.
    reg [31:0] div = 0;
    always @(posedge CLOCK_50)
        div <= div + 1;

    // Slow clock for the CPU (divide by ~2^26)
    wire cpu_clk = div[25];

    // ======================================================
    // CPU Instance (pipelined RV32I)
    // ======================================================
    // The CPU writes to memory-mapped LEDs, and reads the board switches
    cpu_pipeline CPU0 (
        .clk      (cpu_clk),
        .reset    (reset),
        .leds     (LEDR),    // LEDs are fully driven by the CPU via MMIO
        .switches (SW)
    );

endmodule
