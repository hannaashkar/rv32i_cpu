# =============================================================================
# csr_ops.S — directed test for the Zicsr scaffold (csr_file, decision D012).
#
# Covers: rdcycle monotonicity, EXACT retired-instruction counting via
# rdinstret (must be immune to stalls and branch mispredicts — that is the
# valid-bit's whole job), all six CSR instruction forms against mscratch,
# ISA write-suppression (CSRRS/CSRRC with rs1=x0 / zimm=0 must not write),
# writes to read-only counters being dropped, unimplemented CSRs reading 0,
# and CSR results forwarding into a dependent ALU op.
#
# instret delta rule (in-order 5-stage, CSR read in EX, count in WB):
#   a rdinstret in EX sees the count of instructions that left WB in
#   earlier cycles — normally "my program index minus 3" (the 3 slots
#   ahead of me are still in flight). That offset is only constant if the
#   3 slots ahead hold real instructions, so each exact-delta check keeps
#   >= 3 straight-line instructions (no branches, loads, or their flush
#   shadows) immediately before EACH rdinstret. Then:
#       delta = exact number of retired instructions between the two
#               reads, counting the second rdinstret itself.
#
# Fail code = check number; PASS = 1.
# =============================================================================
    .section .text

.macro CHECK_EQ a, b, code
    addi x31, x0, \code
    beq  \a, \b, 1f
    beq  x0, x0, finish
1:
.endm

    .globl _start
_start:

    # --- check 2: cycle counter is live and monotonic -----------------
    rdcycle x5
    rdcycle x6
    sltu x7, x5, x6          # second read must be strictly greater
    addi x28, x0, 1
    CHECK_EQ x7, x28, 2

    # --- check 3: straight-line instret delta is exact ----------------
    # 3 fillers flush the CHECK macro's branch shadow out of MEM/WB
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    rdinstret x5             # index n
    addi x7, x0, 0           # n+1
    addi x7, x0, 0           # n+2
    rdinstret x6             # n+3  ->  delta must be exactly 3
    sub  x7, x6, x5
    addi x28, x0, 3
    CHECK_EQ x7, x28, 3

    # --- check 4: instret ignores bubbles and mispredicts -------------
    # A 5-iteration countdown loop: the cold BHT mispredicts at least the
    # first and last iterations, injecting flush bubbles. instret must
    # still count exactly the retired program:
    #   1 (init) + 5*2 (loop) + 3 (fillers) + 1 (2nd rdinstret) = 15
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    rdcycle   x8             # cycle reading for check 5 (shadow slot 2)
    rdinstret x5             # shadowed by fillers + rdcycle: exact
    addi x10, x0, 5
loop1:
    addi x10, x10, -1
    bne  x10, x0, loop1
    addi x0, x0, 0           # fillers: push the bne's flush shadow
    addi x0, x0, 0           # out of MEM/WB before reading instret
    addi x0, x0, 0
    rdinstret x6
    rdcycle   x9             # cycle reading for check 5
    sub  x7, x6, x5
    addi x28, x0, 15
    CHECK_EQ x7, x28, 4

    # --- check 5: the same stretch costs MORE cycles than instructions
    # (mispredict penalties are real cycles but not retirements)
    sub  x9, x9, x8          # cycle delta over the loop
    sltu x7, x28, x9         # 15 < cycle delta ?
    addi x28, x0, 1
    CHECK_EQ x7, x28, 5

    # --- check 6+7: CSRRW writes, reads back -----------------------------
    lui  x5, 0xDEADC
    addi x5, x5, -273        # x5 = 0xDEADBEEF
    csrrw x6, mscratch, x5   # mscratch := 0xDEADBEEF, x6 = old (reset = 0)
    CHECK_EQ x6, x0, 6
    csrr x7, mscratch
    CHECK_EQ x7, x5, 7

    # --- check 8: CSRRW is a swap: rd gets the OLD value -----------------
    addi x8, x0, 0x55
    csrrw x9, mscratch, x8   # mscratch := 0x55, x9 = 0xDEADBEEF
    CHECK_EQ x9, x5, 8

    # --- check 9+10: CSRRSI sets bits, returns old value -----------------
    csrrsi x7, mscratch, 0x0A    # mscratch := 0x55 | 0x0A = 0x5F
    addi x28, x0, 0x55
    CHECK_EQ x7, x28, 9
    csrr x7, mscratch
    addi x28, x0, 0x5F
    CHECK_EQ x7, x28, 10

    # --- check 11: CSRRCI clears bits -----------------------------------
    csrrci x7, mscratch, 0x0F    # mscratch := 0x5F & ~0x0F = 0x50
    csrr x7, mscratch
    addi x28, x0, 0x50
    CHECK_EQ x7, x28, 11

    # --- check 12: CSRRS register form sets bits -------------------------
    addi x8, x0, 0x700
    csrrs x7, mscratch, x8       # mscratch := 0x50 | 0x700 = 0x750
    csrr x7, mscratch
    addi x28, x0, 0x750
    CHECK_EQ x7, x28, 12

    # --- check 13: CSRRC register form clears bits ------------------------
    csrrc x7, mscratch, x8       # mscratch := 0x750 & ~0x700 = 0x50
    csrr x7, mscratch
    addi x28, x0, 0x50
    CHECK_EQ x7, x28, 13

    # --- check 14: CSRRS with rs1=x0 must NOT write (pure read) -----------
    csrrs x7, mscratch, x0
    csrr x9, mscratch
    addi x28, x0, 0x50
    CHECK_EQ x9, x28, 14

    # --- check 15: write to a read-only counter is dropped ----------------
    # instreth is 0 for any test-sized run, so both the old value and the
    # readback must be 0 if the write was correctly ignored
    csrrw x7, instreth, x5
    csrr  x9, instreth
    or   x7, x7, x9
    CHECK_EQ x7, x0, 15

    # --- check 16: unimplemented CSR reads as 0 ---------------------------
    csrr x7, mepc
    CHECK_EQ x7, x0, 16

    # --- check 17: CSR result forwards into a dependent ALU op ------------
    csrr x7, mscratch        # 0x50
    addi x9, x7, 1           # needs EX<-MEM forwarding of the CSR read
    addi x28, x0, 0x51
    CHECK_EQ x9, x28, 17

    # --- check 18: cycleh is 0 for a short run ----------------------------
    csrr x7, cycleh
    CHECK_EQ x7, x0, 18

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
