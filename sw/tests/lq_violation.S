# =============================================================================
# lq_violation.S — FORCE a memory-ordering violation to exercise the LQ
# poison + flush-at-head recovery (D020).
#
# Recipe: make an OLDER store's ADDRESS depend on a long latency chain, while
# a YOUNGER load to the SAME address has its address ready immediately. With
# speculative loads the young load issues early, reads the OLD value, then the
# older store computes its (matching) address and writes -> violation -> the
# load must be squashed + replayed and re-read the NEW value.
#
# Correctness is value-based: after the store, the reloaded value MUST be the
# stored one. If the violation recovery is broken, the load keeps its stale
# read and the check fails. Fail code in x31 (2 = stale after violation).
# Exit: store x31 to 0x40000008 (1 = PASS).
# =============================================================================
    .section .text
    .globl _start
_start:
    # base address (word 20 in dmem) in x6
    addi x6, x0, 80                 # byte addr 80 = word 20

    # seed memory at [x6] with a known OLD value
    addi x7, x0, 111
    sw   x7, 0(x6)

    # ---- the violation window ----
    # x10 = a VERY long dependency chain so the STORE address resolves LATE,
    # guaranteeing the younger load issues speculatively first regardless of
    # micro-timing (division-like latency via a long serial add chain).
    addi x10, x0, 0
    .rept 120
    addi x10, x10, 1                # 120-deep serial chain
    .endr
    sub  x11, x10, x10             # x11 = 0 (depends on the long chain)
    add  x12, x6, x11             # x12 = x6 + 0 = x6, but resolves LATE
    addi x8, x0, 222              # the NEW value to store
    sw   x8, 0(x12)              # OLDER store, address x12 (== x6) resolves late

    lw   x9, 0(x6)              # YOUNGER load, address x6 ready immediately
    # x9 must equal 222 (the store above is older in program order).
    addi x31, x0, 2            # preload fail code
    beq  x9, x8, ok1
    beq  x0, x0, finish        # x9 != 222 -> stale load (violation not repaired)
ok1:
    # ---- repeat the pattern a few times to hit the CAM repeatedly ----
    addi x6, x6, 4             # next word
    addi x13, x0, 333
    addi x14, x0, 0
    .rept 20
    addi x14, x14, 1
    .endr
    sub  x15, x14, x14        # 0, late
    add  x16, x6, x15
    sw   x13, 0(x16)          # older store (late addr)
    lw   x17, 0(x6)           # younger load (early addr)
    addi x31, x0, 3
    bne  x17, x13, finish     # must see 333

    addi x31, x0, 1           # PASS
finish:
    # build 0x40000008 by doubling
    addi x1, x0, 1
    .rept 30
    add  x1, x1, x1
    .endr
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
