# =============================================================================
# stset_predict.S — store-set predictor training regression (D021).
#
# The SAME static (store, load) PC pair violates on its first execution (cold
# SSIT: the store's address resolves late, the younger load's is ready, so a
# speculative load reads stale) — that violation TRAINS the predictor. Every
# later loop iteration re-executes the same PCs; a working predictor makes
# the load WAIT for its producer store instead of re-violating each time.
#
# Correctness is value-based and policy-independent: each iteration stores a
# fresh value and the load must observe it (flush-at-head recovery repairs
# the cold iteration under policies 1/2; conservative waiting makes it
# trivial under policy 0). The PREDICTIVE claim — violations drop from
# once-per-iteration to ~1 total — is measured in D021 via +define+LQ_PROBE
# violation counts, not asserted here.
# Fail code: 2 = load observed a wrong value. Exit: x31 -> 0x40000008.
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x6, x0, 128            # base byte address (dmem word 32)
    addi x20, x0, 6             # loop iterations
    addi x21, x0, 100           # value seed
    addi x31, x0, 2             # preload fail code

loop:
    addi x21, x21, 11           # fresh value this iteration
    # long serial chain: the store's ADDRESS depends on it, so it resolves
    # late while the load's address is ready immediately
    addi x10, x0, 0
    .rept 60
    addi x10, x10, 1
    .endr
    sub  x11, x10, x10          # 0, but depends on the whole chain
    add  x12, x6, x11           # == x6, resolves late
    sw   x21, 0(x12)            # OLDER store, late address (same PC each iter)
    lw   x9, 0(x6)              # YOUNGER load, early address (same PC each iter)
    bne  x9, x21, finish        # must observe THIS iteration's value
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
