# =============================================================================
# mem_ops.S — directed test for sub-word memory access (SB/SH/LB/LBU/LH/LHU).
#
# Covers: every byte lane, both half lanes, sign vs zero extension,
# neighbor bytes untouched by SB/SH, and word/byte interleaving.
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
    addi x6, x0, 128         # base address (word 32)

    # --- fill a word with a known pattern via SW ---
    lui  x5, 0x81828
    addi x5, x5, 0x384       # x5 = 0x81828384
    sw   x5, 0(x6)

    # --- LBU each lane: 84, 83, 82, 81 (little-endian) ---
    lbu  x7, 0(x6)
    addi x28, x0, 0x84
    CHECK_EQ x7, x28, 2
    lbu  x7, 1(x6)
    addi x28, x0, 0x83
    CHECK_EQ x7, x28, 3
    lbu  x7, 2(x6)
    addi x28, x0, 0x82
    CHECK_EQ x7, x28, 4
    lbu  x7, 3(x6)
    addi x28, x0, 0x81
    CHECK_EQ x7, x28, 5

    # --- LB sign-extends: 0x84 -> 0xFFFFFF84 ---
    lb   x7, 0(x6)
    addi x28, x0, 0x84
    addi x29, x0, -1
    slli x29, x29, 8         # 0xFFFFFF00
    or   x28, x28, x29       # 0xFFFFFF84
    CHECK_EQ x7, x28, 6

    # --- LHU both lanes: 0x8384, 0x8182 ---
    lhu  x7, 0(x6)
    lui  x28, 0x8
    addi x28, x28, 0x384     # 0x8384
    CHECK_EQ x7, x28, 7
    lhu  x7, 2(x6)
    lui  x28, 0x8
    addi x28, x28, 0x182     # 0x8182
    CHECK_EQ x7, x28, 8

    # --- LH sign-extends: 0x8384 -> 0xFFFF8384 ---
    lh   x7, 0(x6)
    lui  x28, 0xFFFF8
    addi x28, x28, 0x384     # 0xFFFF8384
    CHECK_EQ x7, x28, 9

    # --- SB updates one lane only ---
    addi x5, x0, 0x5A
    sb   x5, 1(x6)           # word becomes 0x81825A84
    lw   x7, 0(x6)
    lui  x28, 0x81826
    addi x28, x28, -1404     # 0x81826000 - 0x57C = 0x81825A84
    CHECK_EQ x7, x28, 10

    # --- SH updates one half only ---
    lui  x5, 0xC
    addi x5, x5, -256        # 0xBF00
    sh   x5, 2(x6)           # upper half := 0xBF00 -> word 0xBF005A84
    lw   x7, 0(x6)
    lui  x28, 0xBF006
    addi x28, x28, -1404     # 0xBF006000 - 0x57C = 0xBF005A84
    CHECK_EQ x7, x28, 11

    # --- byte write then byte read at another address ---
    addi x6, x0, 512
    addi x5, x0, -3          # 0xFD
    sb   x5, 3(x6)
    lbu  x7, 3(x6)
    addi x28, x0, 0xFD
    CHECK_EQ x7, x28, 12
    lb   x7, 3(x6)
    addi x28, x0, -3
    CHECK_EQ x7, x28, 13

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
