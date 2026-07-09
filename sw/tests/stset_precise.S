# =============================================================================
# stset_precise.S — precision microbench: store sets (policy 2) vs a
# 21264-style 1-bit load-wait table (policy 3). Value-checked, so it doubles
# as a regression under every policy; the POINT is the measured cycle gap.
#
# Design note (v2): the load must be LOOP-CARRIED or the gap is invisible —
# in a 32-entry-ROB machine, in-order retirement of the long address chains
# hides *when* a tail load issued (measured: an end-of-body load gave
# policy 2 == policy 3 exactly). So L_B is a self-pointer chase: x6 = [x6],
# and both address chains reseed from x6, putting L_B's issue time on the
# critical path of every following iteration.
#
# Loop body (program order):
#   chainA (20 adds, seeded from x6) -> S_A stores junk to word A, address
#     resolves LATE every iteration;
#   chainB (3 adds, seeded from x6)  -> S_B stores the pointer back to
#     word B, address resolves EARLY-ish;
#   L_B: lw x6, 0(x6) — address ready immediately, TRAINED onto S_B by the
#     iteration-1 violation (S_A writes a different word and never violates
#     or joins the set).
# After training:
#   policy 2 (store sets):  L_B waits only for S_B          -> short iter
#   policy 3 (1-bit table): a trained load waits for ALL older unresolved
#     store addresses, i.e. ALSO the slow S_A               -> long iter
# cycles(policy 3) - cycles(policy 2) over 20 iterations is the measured
# value of dependence PRECISION — the Chrysos & Emer scenario on this RTL
# (docs/STORESET.md / D021).
# Fail code: 2 = pointer corrupted. Exit: x31 -> 0x40000008 (1 = PASS).
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x5, x0, 320            # word A (junk target)
    addi x6, x0, 360            # word B — the self-pointer word
    addi x30, x6, 0             # expected pointer value (== B)
    sw   x6, 0(x6)              # seed memory[B] = B
    addi x20, x0, 20            # iterations
    addi x21, x0, 40            # junk value seed
    addi x31, x0, 2             # preload fail code

loop:
    addi x21, x21, 3
    # chainA: long, reseeded from the loop-carried x6 -> S_A's address is
    # the LAST older-store address to resolve, every iteration
    addi x10, x6, 0
    .rept 20
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10          # 0, late
    add  x12, x5, x11           # word A, resolves late
    sw   x21, 0(x12)            # S_A — older, slow, unrelated word
    # chainB: short, also reseeded from x6 -> S_B resolves much earlier
    addi x13, x6, 0
    .rept 3
    addi x13, x13, 1
    .endr
    sub  x14, x13, x13          # 0, slightly late
    add  x15, x6, x14           # word B, resolves early-ish
    sw   x6, 0(x15)             # S_B — the true producer (stores the pointer)
    lw   x6, 0(x6)              # L_B — loop-carried self-pointer chase
    bne  x6, x30, finish        # the pointer must remain B
    addi x20, x20, -1
    bne  x20, x0, loop

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
