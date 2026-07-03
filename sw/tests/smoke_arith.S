# =============================================================================
# smoke_arith.S — first Verilator smoke test.
#
# Uses ONLY the currently-working ISA subset (see CLAUDE.md): ADDI, ADD,
# BEQ, SW. Computes 2 + 3, checks the result, and reports via the test-end
# protocol: store to 0x40000008 — value 1 = PASS, anything else = FAIL.
#
# No LUI or shifts exist yet, so the MMIO address is built by repeated
# doubling (add x1,x1,x1 is a logical shift-left by 1).
#
# Hazard note: the store data register (x31) is written many cycles before
# the SW on purpose — store-data forwarding is missing (BUGLOG B007), so a
# freshly-computed value would be stored stale.
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x5, x0, 2
    addi x6, x0, 3
    add  x7, x5, x6          # x7 = 5 (exercises EX<-MEM forwarding on x6)
    addi x28, x0, 5
    beq  x7, x28, pass       # exercises branch resolution in EX
fail:
    addi x31, x0, 2          # FAIL code 2
    beq  x0, x0, finish
pass:
    addi x31, x0, 1          # PASS
finish:
    addi x1, x0, 1
    .rept 30
    add  x1, x1, x1          # x1 <<= 1; after 30 doublings x1 = 0x40000000
    .endr
    addi x1, x1, 8           # x1 = 0x40000008 (sim-exit address)
    sw   x31, 0(x1)          # harness ends the simulation here
hang:
    beq  x0, x0, hang        # safety net if the store is missed
