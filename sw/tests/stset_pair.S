# =============================================================================
# stset_pair.S — store-set corner regressions (D021): co-dispatched pairs,
# in-set store->store ordering, stale-LFST self-healing.
#
# A: adjacent sw/lw to the same address (the hello.c stack-spill shape). The
#    two uops can rename/dispatch in the SAME cycle (slot0 store + slot1
#    load); after training, the slot1 load's wait must come from the
#    predictor's same-cycle LFST bypass. (Without the bypass this stays
#    value-correct but re-violates every iteration — visible in the D021
#    LQ_PROBE counts, which is exactly what the bypass exists to prevent.)
# B: TWO same-set stores in flight (older S1 slow-address, younger S2
#    faster) + an early load. Iteration 1 violates against both stores and
#    merges {S1, S2, L} into one set; from then on S2 must wait for S1
#    (in-set store ordering) and L for S2, transitively covering both. The
#    load must observe S2's (the younger store's) value every iteration.
# C: stale-LFST self-heal: after training, one iteration branch-SKIPS the
#    store, leaving the load's LFST entry pointing at a drained/reused SQ
#    slot. The masked (ANDed) wait must self-heal — the load reads the last
#    written value promptly and the machine must not stall (the ROB-head
#    watchdog assertion would catch a hang).
# Fail codes: 2/3/4 = wrong value in part A/B/C. Exit: x31 -> 0x40000008.
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x6, x0, 160            # part A word
    addi x7, x0, 200            # part B word
    addi x8, x0, 240            # part C word

    # ---------------- part A: co-dispatched sw/lw pair -----------------
    addi x20, x0, 5
    addi x21, x0, 300
    addi x31, x0, 2
loopA:
    addi x21, x21, 13
    addi x10, x0, 0
    .rept 40
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10
    add  x12, x6, x11           # == x6, resolves late
    .balign 8                   # bias sw to fetch-slot0, lw to slot1
    sw   x21, 0(x12)            # older store, late operands
    lw   x9,  0(x6)             # younger load, ready — co-dispatched pair
    bne  x9, x21, finish
    addi x20, x20, -1
    bne  x20, x0, loopA

    # ------- part B: in-set chain S1(slow) -> S2(faster) -> L(early) ----
    addi x20, x0, 5
    addi x22, x0, 500           # S1 value seed
    addi x23, x0, 900           # S2 value seed
    addi x31, x0, 3
loopB:
    addi x22, x22, 3
    addi x23, x23, 7
    addi x10, x0, 0
    .rept 60
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10
    add  x12, x7, x11           # S1 address, very late
    addi x13, x0, 0
    .rept 25
    addi x13, x13, 1
    .endr
    sub  x14, x13, x13
    add  x15, x7, x14           # S2 address, moderately late, SAME word
    sw   x22, 0(x12)            # S1: older, slowest
    sw   x23, 0(x15)            # S2: younger, faster
    lw   x9,  0(x7)             # L: earliest-ready — must see S2's value
    bne  x9, x23, finish
    addi x20, x20, -1
    bne  x20, x0, loopB

    # ---------------- part C: stale LFST self-heal ---------------------
    addi x24, x0, 777
    sw   x24, 0(x8)             # seed the memory value
    addi x20, x0, 4
    addi x25, x0, 1000
    addi x31, x0, 4
loopC:
    addi x25, x25, 9
    addi x10, x0, 0
    .rept 40
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10
    add  x12, x8, x11           # == x8, resolves late
    addi x26, x0, 2
    beq  x20, x26, skipC        # SKIP the store on the x20==2 iteration
    sw   x25, 0(x12)            # older store (trains with the lw below)
    addi x24, x25, 0            # x24 = the last value actually stored
skipC:
    lw   x9, 0(x8)              # must equal the last stored value
    bne  x9, x24, finish
    addi x20, x20, -1
    bne  x20, x0, loopC

    addi x31, x0, 1             # PASS
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
