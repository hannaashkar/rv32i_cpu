# ============================================================================
# led_demo.S — self-paced LED walker (B005 / D017)
#
# The CPU now runs at the full 50 MHz PLL clock; the slow ripple clock that
# used to make LED activity visible by eye is gone (B005). This demo paces
# itself in SOFTWARE instead: a single lit LED walks LED0 -> LED9 -> LED0,
# with a delay loop between steps sized for a human-visible rate (~0.2 s).
#
# Pure bare-metal: entry at address 0 (imem), no runtime, loops forever.
# Writes the 10-bit pattern to the LED MMIO register at 0x4000_0000.
# ============================================================================
    .section .text
    .globl _start
_start:
    li   t0, 0x40000000        # LED MMIO base (IO region 0x4xxxxxxx)
    li   t1, 1                 # walking bit — start at LED0

walk:
    sw   t1, 0(t0)             # drive the 10 LEDs

    slli t1, t1, 1             # walk one LED to the left
    li   t2, 0x400             # bit 10 = just past LED9 (LEDs are bits 0..9)
    bne  t1, t2, delay_setup
    li   t1, 1                 # wrapped past LED9 -> restart at LED0

delay_setup:
    li   t3, 6000000           # ~6M * ~2 cyc / 50 MHz ~ 0.24 s per step
delay:
    addi t3, t3, -1
    bnez t3, delay

    j    walk
