# ============================================================================
# rv32i_cpu.sdc — timing constraints (B005, decision D017)
#
# DE10-Lite: a 50 MHz oscillator drives CLOCK_50 (PIN_P11). Until now the CPU
# ran off bit 25 of a free-running counter (a "ripple" clock) with no .sdc, so
# STA had nothing real to check (setup slack -13 ns on that domain). The core
# is now clocked by a PLL-generated clock; this file constrains the board
# clock and lets Quartus derive the PLL outputs, giving an honest Fmax.
# ============================================================================

# --- Board reference clock --------------------------------------------------
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]

# --- PLL-generated clocks (cpu_clk = pll|c0) --------------------------------
# derive_pll_clocks names and constrains every PLL output from its settings,
# so the CPU clock is analyzed at its real (post-PLL) frequency.
derive_pll_clocks
derive_clock_uncertainty

# --- Asynchronous / non-critical I/O ----------------------------------------
# KEY[0] is a pushbutton reset (double-flop synchronized in RTL); SW are
# switch inputs read by MMIO; LEDR are driven by MMIO. None are part of a
# synchronous board interface, so they carry no meaningful I/O timing.
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]
set_false_path -from [all_registers] -to [get_ports {LEDR[*]}]
