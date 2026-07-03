# =============================================================================
# crt0.S — C runtime startup for rv32i_cpu bare-metal programs
#
# Linked first into .text (section .text.init), so _start executes at pc=0.
# Sets up the three things compiled C assumes exist, then calls main():
#   sp  — top of dmem (_stack_top from link.ld), 16-byte aligned per ABI
#   gp  — __global_pointer$, the anchor for gp-relative small-data access.
#         Loaded with relaxation disabled: otherwise the linker would relax
#         this very instruction into "mv gp, gp" (gp is what it's defining).
#   .bss — zeroed. The dmem image only carries initialized sections; sim
#         zeroes dmem anyway, but the FPGA and back-to-back runs do not.
#
# Exit protocol (same as the assembly tests / Verilator harness):
#   main() returned 0  ->  store 1 (PASS) to 0x40000008
#   main() returned x  ->  store x (FAIL code) to 0x40000008
#   NOTE a fail code of 1 would read as PASS — main() must not return 1
#   to signal failure.
# =============================================================================
    .section .text.init
    .globl _start
_start:
.option push
.option norelax
    la   gp, __global_pointer$
.option pop
    la   sp, _stack_top

    # ---- zero .sbss/.bss (word-aligned by link.ld) ----
    la   t0, __bss_start
    la   t1, __bss_end
    bgeu t0, t1, 2f
1:
    sw   x0, 0(t0)
    addi t0, t0, 4
    bltu t0, t1, 1b
2:
    call main

    # ---- report result ----
    bnez a0, 3f
    addi a0, x0, 1           # 0 -> PASS code
3:
    lui  t0, 0x40000
    sw   a0, 8(t0)           # sim-exit MMIO register
4:
    j    4b                  # on real hardware (no harness) just park

    # 4-byte sentinel pinning the dmem image origin to 0x10000000 —
    # see link.ld for why this must always exist.
    .section .dmem_origin, "a"
    .word 0x64617461         # spells "data"
