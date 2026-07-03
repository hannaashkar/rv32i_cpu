# =============================================================================
# branch_ops.S — directed test for the dedicated branch unit (D007/B2).
# Every RV32I conditional branch, taken AND not-taken, with signed/unsigned
# boundary values (-1 vs 1 distinguishes BLT from BLTU).
# Fail code = check number; PASS = 1.
# =============================================================================
    .section .text

# Branch must be TAKEN; falling through = fail
.macro CHECK_TAKEN insn, a, b, code
    addi x31, x0, \code
    \insn \a, \b, 1f
    beq   x0, x0, finish
1:
.endm

# Branch must NOT be taken; jumping = fail
.macro CHECK_NOT_TAKEN insn, a, b, code
    addi x31, x0, \code
    \insn \a, \b, 1f
    beq   x0, x0, 2f
1:
    beq   x0, x0, finish
2:
.endm

    .globl _start
_start:
    addi x5, x0, -1          # signed: -1     unsigned: 0xFFFFFFFF (max)
    addi x6, x0, 1
    addi x7, x0, 1           # equal partner for x6

    # --- BEQ ---
    CHECK_TAKEN     beq, x6, x7, 2
    CHECK_NOT_TAKEN beq, x5, x6, 3

    # --- BNE (executed as BEQ before this change) ---
    CHECK_TAKEN     bne, x5, x6, 4
    CHECK_NOT_TAKEN bne, x6, x7, 5

    # --- BLT: signed, so -1 < 1 ---
    CHECK_TAKEN     blt, x5, x6, 6
    CHECK_NOT_TAKEN blt, x6, x5, 7
    CHECK_NOT_TAKEN blt, x6, x7, 8    # equal -> not less

    # --- BGE: signed, >= ---
    CHECK_TAKEN     bge, x6, x5, 9
    CHECK_TAKEN     bge, x6, x7, 10   # equal -> taken
    CHECK_NOT_TAKEN bge, x5, x6, 11

    # --- BLTU: unsigned, so 1 < 0xFFFFFFFF ---
    CHECK_TAKEN     bltu, x6, x5, 12
    CHECK_NOT_TAKEN bltu, x5, x6, 13
    CHECK_NOT_TAKEN bltu, x6, x7, 14  # equal -> not less

    # --- BGEU: unsigned, >= ---
    CHECK_TAKEN     bgeu, x5, x6, 15
    CHECK_TAKEN     bgeu, x6, x7, 16  # equal -> taken
    CHECK_NOT_TAKEN bgeu, x6, x5, 17

    # --- backward taken branch (negative B-immediate) in a real loop ---
    addi x9, x0, 0
    addi x10, x0, 3
loop:
    addi x9, x9, 1
    bne  x9, x10, loop       # loops 3 times, exercises predictor learning
    addi x31, x0, 18
    beq  x9, x10, 1f
    beq  x0, x0, finish
1:

    addi x31, x0, 1          # PASS
finish:
    addi x1, x0, 1
    slli x1, x1, 30
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
