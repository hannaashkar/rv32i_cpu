# =============================================================================
# fetch_hold_redirect.S — banked-imem fetch fold regressions (D022).
#
# Hammers the corners of the F/D fold onto imem_banked's read registers:
#   (a) hold-under-backpressure (the B012 shape): a 6-deep dependent-load
#       chain serializes the machine, so fd_accept drops for long windows
#       while the held F/D pair must stay frozen in the ROM's read registers.
#   (b) redirect-while-held: an xorshift32-directed branch is unlearnable by
#       gshare (~50% mispredict rate forever), so EX redirects (restore_en)
#       keep landing while fetch is held. Both its paths add the SAME
#       constant, keeping the signature path-independent (lockstep is the
#       path oracle); a second, parity-alternating branch adds path-DISTINCT
#       constants with exactly-known counts (100 even / 100 odd).
#   (c) crossbar polarity: xtaken / podd / sigfunc sit at pc%8==4 (odd word)
#       while the fall-through paths run even-aligned — every redirect and
#       return exercises both sel_q polarities of the output crossbar.
#   (d) decode redirects: a JAL join per path (BTB-cold then BTB-hit) and a
#       call/ret pair through the RAS every iteration.
# 200 iterations. Expected signature = 100*0x111 + 100*0x222 + 200*0x333
# + 200*0x55 = 300*0x333 + 200*0x55 = 262700, rebuilt at the end by
# shift-adds. Fail codes: 2 = signature mismatch, 3 = load chain broken.
# Exit: x31 -> 0x40000008 (1 = PASS).
# =============================================================================
    .section .text
    .globl _start
_start:
    addi x6, x0, 128            # chain word address (dmem, self-pointing)
    sw   x6, 0(x6)              # mem[128] = 128
    addi x20, x0, 200           # iteration counter
    addi x28, x0, 0             # signature accumulator
    lui  x22, 0x12345
    addi x22, x22, 0x678        # xorshift32 state
    addi x31, x0, 2             # default fail code (signature mismatch)

loop:
    # (a) backpressure: each load's address depends on the previous load
    add  x10, x6, x0
    lw   x10, 0(x10)
    lw   x10, 0(x10)
    lw   x10, 0(x10)
    lw   x10, 0(x10)
    lw   x10, 0(x10)
    lw   x10, 0(x10)
    bne  x10, x6, chainfail

    # (b) xorshift32 step; branch on bit 0 — unpredictable forever
    slli x11, x22, 13
    xor  x22, x22, x11
    srli x11, x22, 17
    xor  x22, x22, x11
    slli x11, x22, 5
    xor  x22, x22, x11
    andi x11, x22, 1
    bne  x11, x0, xtaken
    addi x28, x28, 0x55         # not-taken path (same constant as taken)
    jal  x0, xjoin
    .balign 8
    nop
xtaken:                          # pc%8 == 4: odd-word redirect target
    addi x28, x28, 0x55
xjoin:

    # (c) parity branch: alternates every iteration, path-distinct constants
    andi x11, x20, 1
    bne  x11, x0, podd
    addi x28, x28, 0x222        # even-x20 iterations (100 of them)
    jal  x0, pjoin
    .balign 8
    nop
podd:                            # odd-word redirect target again
    addi x28, x28, 0x111        # odd-x20 iterations (100 of them)
pjoin:

    # (d) call/ret through the RAS every iteration
    jal  x1, sigfunc

    addi x20, x20, -1
    bne  x20, x0, loop

    # rebuild the expected signature: 300*0x333 + 200*0x55
    addi x29, x0, 0x333
    slli x30, x29, 8
    slli x11, x29, 5
    add  x30, x30, x11
    slli x11, x29, 3
    add  x30, x30, x11
    slli x11, x29, 2
    add  x30, x30, x11          # 300*0x333 (256+32+8+4)
    addi x29, x0, 0x55
    slli x11, x29, 7
    add  x30, x30, x11
    slli x11, x29, 6
    add  x30, x30, x11
    slli x11, x29, 3
    add  x30, x30, x11          # + 200*0x55 (128+64+8)
    bne  x28, x30, finish       # x31 still 2 on mismatch
    addi x31, x0, 1             # PASS
    jal  x0, finish

chainfail:
    addi x31, x0, 3

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

    .balign 8
    nop
sigfunc:                         # pc%8 == 4: odd-word call target
    addi x28, x28, 0x333
    jalr x0, x1, 0               # ret (RAS decode redirect)
