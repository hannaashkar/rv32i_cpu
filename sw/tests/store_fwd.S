# =============================================================================
# store_fwd.S — directed test for BUGLOG B007 (store data bypasses forwarding).
#
# Case 1 (EX<-MEM distance): value computed by the instruction IMMEDIATELY
#   before the SW. Buggy core stores the stale register value (0).
# Case 2 (EX<-WB distance): value computed two instructions before the SW.
#   Also broken pre-fix, since EX/MEM latches raw rs2_dataE.
#
# Fail codes: 2 = case 1 stored stale data, 3 = case 2 stored stale data.
# =============================================================================
    .section .text
    .globl _start
_start:
    # ---- case 1: producer directly before store ----
    addi x5, x0, 21
    addi x6, x0, 64          # dmem byte address 64 (word 16)
    add  x7, x5, x5          # x7 = 42
    sw   x7, 0(x6)           # store data needs EX<-MEM forward (B007)
    lw   x8, 0(x6)
    addi x31, x0, 2          # preload fail code for case 1
    beq  x8, x7, case2
    beq  x0, x0, finish      # x8 != 42 -> stale store
case2:
    # ---- case 2: producer two before store (WB forward) ----
    addi x9, x0, 7
    addi x0, x0, 0           # spacer -> producer is in WB when sw is in EX
    sw   x9, 4(x6)
    lw   x10, 4(x6)
    addi x31, x0, 3          # preload fail code for case 2
    beq  x10, x9, pass
    beq  x0, x0, finish
pass:
    addi x31, x0, 1          # PASS
finish:
    # Build 0x40000008 by repeated doubling (no LUI/shifts on this core yet)
    addi x1, x0, 1
    .rept 30
    add  x1, x1, x1
    .endr
    addi x1, x1, 8
    sw   x31, 0(x1)          # sim-exit store (x31 written long before: safe)
hang:
    beq  x0, x0, hang
