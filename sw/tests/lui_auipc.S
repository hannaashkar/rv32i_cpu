# =============================================================================
# lui_auipc.S — directed test for LUI and AUIPC (decision D009/D1).
#
# LUI is checked against the same constant built byte-by-byte with
# addi+slli (already verified in alu_ops.S). AUIPC is checked
# position-independently: two auipc instructions 4 bytes apart must differ
# by exactly 4, and a nonzero U-immediate adds imm<<12 on top.
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
    # --- LUI basic: 0xDEADB000 (sign bit set — must not sign-mangle) ---
    lui  x5, 0xDEADB
    addi x6, x0, 222         # 0xDE
    slli x6, x6, 8
    addi x6, x6, 173         # 0xAD
    slli x6, x6, 8
    addi x6, x6, 176         # 0xB0
    slli x6, x6, 8           # x6 = 0xDEADB000
    CHECK_EQ x5, x6, 2

    # --- LUI + ADDI with negative low part: standard li pattern ---
    # 0x12345678 = (0x12345 << 12) + 0x678
    lui  x5, 0x12345
    addi x5, x5, 0x678
    addi x6, x0, 0x12
    slli x6, x6, 8
    addi x6, x6, 0x34
    slli x6, x6, 8
    addi x6, x6, 0x56
    slli x6, x6, 8
    addi x6, x6, 0x78
    CHECK_EQ x5, x6, 3

    # --- AUIPC relative: two auipc 4 bytes apart differ by exactly 4 ---
    auipc x5, 0
    auipc x6, 0
    sub  x7, x6, x5
    addi x28, x0, 4
    CHECK_EQ x7, x28, 4

    # --- AUIPC with immediate: (pc + (1<<12)) - pc' == 4096 - 4 + 8? ---
    # auipc x5,0 at pc P; auipc x6,1 at P+4 -> x6 - x5 = 4 + 4096
    auipc x5, 0
    auipc x6, 1
    sub  x7, x6, x5
    addi x28, x0, 1
    slli x28, x28, 12
    addi x28, x28, 4         # 4100
    CHECK_EQ x7, x28, 5

    # --- LUI into x0 is discarded ---
    lui  x0, 0xFFFFF
    add  x9, x0, x0
    CHECK_EQ x9, x0, 6

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000         # exit address via LUI (now that it works)
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
