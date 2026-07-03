# =============================================================================
# alu_ops.S — directed test for the flattened ALU decode (decision D006/A2):
# shifts, SLTU/SLTIU, logic ops, and the B004 regression (ADDI with an
# immediate whose bits [11:5] == 0100000 must NOT decode as SUB).
#
# Only ADDI/ADD/BEQ/SW are trusted as scaffolding (already covered by
# smoke_arith/store_fwd); everything else here is under test.
# Fail code = check number; PASS = 1.
# =============================================================================
    .section .text

# CHECK a == b, else fail with CODE. Preloads x31 early (safe w.r.t. stores).
.macro CHECK_EQ a, b, code
    addi x31, x0, \code
    beq  \a, \b, 1f
    beq  x0, x0, finish
1:
.endm

    .globl _start
_start:
    # --- B004 regression: addi with imm=1024 (imm[11:5]=0100000) ---
    addi x5, x0, 1024        # B004 decode computed 0-1024 = -1024 instead
    addi x6, x0, 1           # build 1024 independently by doubling
    add  x6, x6, x6          # 2
    add  x6, x6, x6          # 4
    add  x6, x6, x6          # 8
    add  x6, x6, x6          # 16
    add  x6, x6, x6          # 32
    add  x6, x6, x6          # 64
    add  x6, x6, x6          # 128
    add  x6, x6, x6          # 256
    add  x6, x6, x6          # 512
    add  x6, x6, x6          # 1024
    CHECK_EQ x5, x6, 2

    # --- SLLI: 3 << 4 == 48 ---
    addi x5, x0, 3
    slli x5, x5, 4
    addi x6, x0, 48
    CHECK_EQ x5, x6, 3

    # --- SLL by register, shamt taken from rs2[4:0]: 3 << 33 == 3 << 1 ---
    addi x5, x0, 3
    addi x7, x0, 33
    sll  x5, x5, x7
    addi x6, x0, 6
    CHECK_EQ x5, x6, 4

    # --- SRLI: 0x80000000 >> 31 == 1 (0x80000000 built with slli) ---
    addi x5, x0, 1
    slli x5, x5, 31
    srli x5, x5, 31
    addi x6, x0, 1
    CHECK_EQ x5, x6, 5

    # --- SRAI: -16 >> 2 == -4 (arithmetic keeps the sign) ---
    addi x5, x0, -16
    srai x5, x5, 2
    addi x6, x0, -4
    CHECK_EQ x5, x6, 6

    # --- SRA by register: -1 >> 31 == -1 ---
    addi x5, x0, -1
    addi x7, x0, 31
    sra  x5, x5, x7
    addi x6, x0, -1
    CHECK_EQ x5, x6, 7

    # --- SRL on negative: (-1) >>l 28 == 15 ---
    addi x5, x0, -1
    srli x5, x5, 28
    addi x6, x0, 15
    CHECK_EQ x5, x6, 8

    # --- SLT / SLTI signed: -5 < 3 ---
    addi x5, x0, -5
    addi x6, x0, 3
    slt  x7, x5, x6
    addi x28, x0, 1
    CHECK_EQ x7, x28, 9
    slti x7, x5, -4          # -5 < -4 -> 1
    CHECK_EQ x7, x28, 10

    # --- SLTU / SLTIU unsigned: 3 < 0xFFFFFFFF (== -1 unsigned max) ---
    addi x5, x0, 3
    addi x6, x0, -1
    sltu x7, x5, x6
    CHECK_EQ x7, x28, 11
    sltu x7, x6, x5          # max unsigned < 3 -> 0
    CHECK_EQ x7, x0, 12
    sltiu x7, x5, -1         # 3 < 0xFFFFFFFF -> 1
    CHECK_EQ x7, x28, 13

    # --- logic ops: AND/OR/XOR and immediates ---
    addi x5, x0, 0x5A5       # 0b0101_1010_0101
    addi x6, x0, 0x0F0
    and  x7, x5, x6
    addi x28, x0, 0x0A0
    CHECK_EQ x7, x28, 14
    or   x7, x5, x6
    addi x28, x0, 0x5F5
    CHECK_EQ x7, x28, 15
    xor  x7, x5, x6
    addi x28, x0, 0x555
    CHECK_EQ x7, x28, 16
    andi x7, x5, 0x50F
    addi x28, x0, 0x505
    CHECK_EQ x7, x28, 17
    ori  x7, x5, 0x05A
    addi x28, x0, 0x5FF
    CHECK_EQ x7, x28, 18
    xori x7, x5, -1          # xor with all-ones == bitwise NOT
    addi x28, x0, 0x5A5
    xor  x7, x7, x28         # NOT(x5) ^ x5 == all ones
    addi x28, x0, -1
    CHECK_EQ x7, x28, 19

    # --- SUB still works (R-type funct7[5]) ---
    addi x5, x0, 100
    addi x6, x0, 58
    sub  x7, x5, x6
    addi x28, x0, 42
    CHECK_EQ x7, x28, 20

    addi x31, x0, 1          # PASS
finish:
    # Exit address 0x40000008; slli is under test but verified above (chk 3-5)
    addi x1, x0, 1
    slli x1, x1, 30
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
