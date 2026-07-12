module de10_top (
    input  wire        CLOCK_50,   // 50 MHz base clock from the DE10 board
    input  wire [1:0]  KEY,        // push buttons (KEY[0] used as reset)
    input  wire [9:0]  SW,         // switches routed to the CPU
    output wire [9:0]  LEDR,       // LEDs driven by the CPU via MMIO
    output wire [7:0]  HEX0,       // 7-segment digits (D023), active-low
    output wire [7:0]  HEX1,       //   segments driven raw by the CPU via
    output wire [7:0]  HEX2,       //   MMIO 0x4000000C / 0x40000014 —
    output wire [7:0]  HEX3,       //   software owns the font, bit 7 = DP
    output wire [7:0]  HEX4,
    output wire [7:0]  HEX5
);

    // ======================================================
    // Clock generation (B005, decision D017)
    // ======================================================
    // The CPU is clocked by a PLL-generated global clock derived from the
    // 50 MHz board oscillator — NOT the old free-running ripple-counter bit
    // (div[25]), which had no meaningful timing and failed STA badly. The
    // real Fmax now comes from the .sdc constraining this clock.
    wire cpu_clk;
    wire pll_locked;

    pll PLL0 (
        .areset (1'b0),
        .inclk0 (CLOCK_50),
        .c0     (cpu_clk),
        .locked (pll_locked)
    );

    // ======================================================
    // Reset synchronization
    // ======================================================
    // Hold the core in reset until the PLL locks, then release under control
    // of the active-low KEY[0] pushbutton, double-flopped into the CPU clock
    // domain to avoid metastability. Asynchronously asserted whenever the PLL
    // drops lock (its output clock is then unusable).
    reg [1:0] rst_sync;
    always @(posedge cpu_clk or negedge pll_locked) begin
        if (!pll_locked)
            rst_sync <= 2'b11;                    // reset asserted while unlocked
        else
            rst_sync <= {rst_sync[0], ~KEY[0]};   // sync the button (active-high)
    end

    wire reset = rst_sync[1];

    // ======================================================
    // CPU Instance (pipelined RV32I)
    // ======================================================
    // The CPU writes to memory-mapped LEDs and reads the board switches.
    // NOTE: the CPU now runs at the full PLL frequency, so a program that
    // wants human-visible LED activity must pace itself in software (delay
    // loops / rdcycle) rather than relying on a slow clock (B005).
    //
    // FPGA top is now the 2-wide OUT-OF-ORDER core (board port, D013/D016).
    // ooo_cpu is a drop-in replacement for cpu_pipeline (identical
    // clk/reset/leds/switches interface); its dmem is block-RAM (SYNC_READ).
    ooo_cpu CPU0 (
        .clk      (cpu_clk),
        .reset    (reset),
        .leds     (LEDR),    // LEDs are fully driven by the CPU via MMIO
        .switches (SW),
        .hex0 (HEX0), .hex1 (HEX1), .hex2 (HEX2),
        .hex3 (HEX3), .hex4 (HEX4), .hex5 (HEX5)
    );

endmodule
