# =============================================================================
# sys_nops.S — directed contract test for instructions implemented as NOPs.
#
# Traps are deliberately outside the current RV32I+Zicsr core scope, and the
# instruction memory is Harvard/read-only. The documented behavior is therefore
# that FENCE, ECALL, EBREAK, and unsupported opcodes retire sequentially with no
# architectural side effects. Lockstep checks the retired PC of every word; the
# checks below additionally prove exact retirement, register/CSR preservation,
# and memory preservation on both cores.
#
# The reserved word has non-zero rd/rs/funct fields to expose accidental partial
# decode. Fail code = check number; PASS = 1.
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
    addi x5, x0, 0x123       # register sentinel
    addi x6, x0, 0x05a       # reserved word encodes rd=x6
    lui  x20, 0x10000        # aliased dmem base = 0x1000_0000
    sw   x5, 0(x20)          # memory sentinel
    csrw mscratch, x5        # CSR sentinel

    # Keep >=3 straight-line instructions before the first instret read so the
    # in-order WB-to-EX offset is stable (same proof as csr_ops.S).
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    rdinstret x10

    .word 0x0ff0000f         # FENCE iorw, iorw
    .word 0x00000073         # ECALL
    .word 0x00100073         # EBREAK
    .word 0x0083f37f         # reserved opcode; rd=x6, rs/funct fields non-zero

    # Flush the four NOPs through WB before the second counter read. Between
    # reads: 4 tested words + 3 fillers + the second rdinstret = delta 8.
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    rdinstret x11
    sub  x12, x11, x10
    addi x28, x0, 8
    CHECK_EQ x12, x28, 2

    # No accidental register write from any partial/default decode.
    addi x28, x0, 0x123
    CHECK_EQ x5, x28, 3
    addi x28, x0, 0x05a
    CHECK_EQ x6, x28, 4

    # ECALL/EBREAK must not enter the CSR path while traps are absent.
    csrr x7, mscratch
    addi x28, x0, 0x123
    CHECK_EQ x7, x28, 5

    # FENCE/reserved decode must not accidentally assert a store control.
    lw   x7, 0(x20)
    CHECK_EQ x7, x28, 6

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang
