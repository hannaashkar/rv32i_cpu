# =============================================================================
# stset_precise.S — precision microbench: store sets (policy 2) vs a
# 21264-style 1-bit load-wait table (policy 3). Value-checked, so it doubles
# as a regression under every policy; the POINT is the measured cycle gap.
#
# Loop body (program order): 120-add chain -> S_A (store to word A, address
# resolves VERY late) -> 25-add chain -> S_B (store to word B, address
# resolves moderately late) -> L_B (load from B, address ready immediately).
#
# Iteration 1: L_B speculates past the unresolved S_B, reads stale B, S_B
# fills -> violation -> trains {S_B, L_B} into one store set. S_A stores to
# a DIFFERENT word, so it never violates L_B and never joins the set. After
# training:
#   policy 2 (store sets):  L_B waits only for S_B          -> short stall
#   policy 3 (1-bit table): a trained load waits for ALL older unresolved
#                           store addresses, i.e. ALSO the slow S_A -> long
# The cycles(policy 3) - cycles(policy 2) gap over the 10 iterations is the
# measured value of dependence PRECISION — the Chrysos & Emer Figure-1
# scenario reproduced on this RTL (see docs/STORESET.md / D021).
# Fail code: 2 = load observed a wrong value. Exit: x31 -> 0x40000008.
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x5, x0, 320            # word A
    addi x6, x0, 360            # word B
    addi x20, x0, 10            # iterations
    addi x21, x0, 40            # A value seed
    addi x22, x0, 70            # B value seed
    addi x31, x0, 2             # preload fail code

loop:
    addi x21, x21, 3
    addi x22, x22, 5
    # S_A's address: a LONG serial chain — the last older-store address to
    # resolve in every iteration
    addi x10, x0, 0
    .rept 120
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10
    add  x12, x5, x11           # == x5 (word A), very late
    sw   x21, 0(x12)            # S_A — never conflicts with L_B
    # S_B's address: a SHORT chain dispatched just before S_B, late enough
    # that the untrained L_B beats its fill (the training violation)
    addi x13, x0, 0
    .rept 25
    addi x13, x13, 1
    .endr
    sub  x14, x13, x13
    add  x15, x6, x14           # == x6 (word B), moderately late
    sw   x22, 0(x15)            # S_B — L_B's true producer
    lw   x9,  0(x6)             # L_B — trained onto S_B after iteration 1
    bne  x9, x22, finish        # must observe THIS iteration's B value
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
