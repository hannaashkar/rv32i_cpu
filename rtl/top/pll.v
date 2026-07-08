// ============================================================================
// pll — MAX 10 ALTPLL wrapper (B005, decision D017)
//
// Purpose:    Replace the free-running ripple-counter "clock" (div[25]) that
//             clocked the CPU with a real, PLL-generated global clock plus a
//             `locked` status used to hold the core in reset until the PLL is
//             stable. This is the prerequisite for any honest Fmax number.
// Interfaces: inclk0 = 50 MHz board clock (CLOCK_50); c0 = CPU clock;
//             locked = PLL lock status; areset = active-high async reset.
// Ratio:      50 MHz -> 16.67 MHz (divide by 3) for the OUT-OF-ORDER top.
//             The OoO issue-queue select was an O(16) serial age-scan (STA:
//             Fmax 8.42 MHz, D018). D019 rewrote it as a balanced log-depth
//             pick tree with parallel dual-port select — IPC-identical, no
//             scheduler pipelining — lifting STA Fmax to 19.65 MHz (slow-85C).
//             The core is clocked at 16.67 MHz, ~15% under that Fmax. The
//             in-order top uses 50 MHz (1:1); only clk0_divide_by changes
//             between the two — the rest of the SoC and the .sdc
//             (derive_pll_clocks) are untouched.
// Notes:      Instantiated directly (not via a generated IP wrapper) so the
//             clocking is self-contained and version-controlled. Quartus
//             recognizes the altpll megafunction natively for MAX 10.
// ============================================================================
module pll (
    input  wire areset,
    input  wire inclk0,     // 50 MHz board clock
    output wire c0,         // CPU clock (PLL clk0)
    output wire locked
);

    wire [4:0] clk_bus;                 // altpll clk[] output bus
    wire [1:0] inclk_bus = {1'b0, inclk0};

    altpll altpll_component (
        .areset            (areset),
        .inclk             (inclk_bus),
        .clk               (clk_bus),
        .locked            (locked),
        // Unused control inputs tied to their inactive values
        .clkena            (6'b111111),
        .extclkena         (4'b1111),
        .clkswitch         (1'b0),
        .configupdate      (1'b0),
        .fbin              (1'b1),
        .pfdena            (1'b1),
        .phasecounterselect(4'b0000),
        .phasestep         (1'b0),
        .phaseupdown       (1'b0),
        .pllena            (1'b1),
        .scanaclr          (1'b0),
        .scanclk           (1'b0),
        .scanclkena        (1'b1),
        .scanread          (1'b0),
        .scanwrite         (1'b0),
        .scandata          (1'b0),
        // Unused outputs
        .activeclock       (),
        .clkbad            (),
        .clkloss           (),
        .enable0           (),
        .enable1           (),
        .extclk            (),
        .fbout             (),
        .fref              (),
        .icdrclk           (),
        .phasedone         (),
        .scandataout       (),
        .scandone          (),
        .sclkout0          (),
        .sclkout1          (),
        .vcooverrange      (),
        .vcounderrange     ()
    );

    defparam
        altpll_component.bandwidth_type         = "AUTO",
        altpll_component.clk0_divide_by         = 3,   // 50 MHz / 3 = 16.67 MHz
        altpll_component.clk0_duty_cycle        = 50,
        altpll_component.clk0_multiply_by       = 1,
        altpll_component.clk0_phase_shift       = "0",
        altpll_component.compensate_clock       = "CLK0",
        altpll_component.inclk0_input_frequency = 20000,   // ps (50 MHz)
        altpll_component.intended_device_family = "MAX 10",
        altpll_component.lpm_type               = "altpll",
        altpll_component.operation_mode         = "NORMAL",
        altpll_component.pll_type               = "AUTO",
        altpll_component.port_areset            = "PORT_USED",
        altpll_component.port_inclk0            = "PORT_USED",
        altpll_component.port_clk0              = "PORT_USED",
        altpll_component.port_locked            = "PORT_USED",
        altpll_component.width_clock            = 5;

    assign c0 = clk_bus[0];

endmodule
