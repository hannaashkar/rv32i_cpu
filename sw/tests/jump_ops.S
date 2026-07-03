# =============================================================================
# jump_ops.S — directed test for JAL/JALR (decision D008/C1).
#
# Checks: jump actually taken (wrong-path marker must not commit), link
# value = pc+4 (verified position-independently against auipc), JALR
# target LSB clearing, negative JALR offsets, and a real call/return.
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
    # --- JAL forward: taken + link value ---
    addi  x9, x0, 0          # wrong-path marker
    auipc x6, 0              # x6 = P
    jal   x5, 1f             # at P+4  -> link must be P+8
    addi  x9, x0, 1          # P+8: must NOT commit (jump skips it)
1:
    addi  x6, x6, 8          # expected link value
    CHECK_EQ x5, x6, 2
    CHECK_EQ x9, x0, 3       # wrong-path instruction never committed

    # --- JALR: taken + link + LSB clearing ---
    auipc x7, 0              # x7 = Q
    addi  x7, x7, 21         # target Q+20, with LSB deliberately set
    jalr  x5, x7, 0          # at Q+8 -> link Q+12, jump to (Q+21)&~1=Q+20
    addi  x9, x0, 2          # Q+12: wrong path, must not commit
    addi  x9, x0, 3          # Q+16: wrong path, must not commit
    # Q+20 lands here:
    auipc x6, 0              # x6 = Q+20
    addi  x6, x6, -8         # expected link = Q+12
    CHECK_EQ x5, x6, 4
    CHECK_EQ x9, x0, 5

    # --- JALR with negative offset ---
    auipc x7, 0              # x7 = R
    addi  x7, x7, 24         # R+24 (= label 2f below)
    jalr  x5, x7, -4         # jump to R+20 (= label 3f)
    addi  x9, x0, 4          # wrong path
    beq   x0, x0, finish     # wrong path (fail code from CHECK below if hit)
3:  # R+20
    addi  x10, x0, 55        # proof we landed at 3f
2:  # R+24
    addi  x31, x0, 6
    addi  x28, x0, 55
    beq   x10, x28, 1f       # must have passed through 3f
    beq   x0, x0, finish
1:
    CHECK_EQ x9, x0, 7

    # --- real call / return (jal + jalr x0) ---
    addi  x10, x0, 0
    jal   x1, func           # call
    addi  x10, x10, 100      # executed after return
    addi  x28, x0, 107
    CHECK_EQ x10, x28, 8

    # --- call the function AGAIN: BTB now holds the first return target,
    #     so this return must mispredict-and-recover correctly ---
    jal   x1, func
    addi  x10, x10, 100
    addi  x28, x0, 214
    CHECK_EQ x10, x28, 9

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang

# ---- leaf function: x10 += 7, return via x1 ----
func:
    addi  x10, x10, 7
    jalr  x0, x1, 0          # ret
