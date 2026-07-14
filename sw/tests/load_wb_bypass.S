# =============================================================================
# load_wb_bypass.S — directed proof for the OoO load-WB consumer contract.
#
# D029 removes an unreachable load-result bypass from the EX critical path.
# This test puts a RAM load immediately before every kind of dependent user:
# JALR, all six branches (both outcomes), ALU, and store address/data.  The
# critical pairs are 8-byte aligned so the OoO front end can co-dispatch the
# load in slot 0 and its dependent consumer in slot 1.
#
# The setup stores are followed by a strongly ordered switch-MMIO load.  The
# OoO core cannot complete that IO load until every older store has drained;
# the test-table base depends on its result.  Therefore the later loads come
# from dmem, not from SQ forwarding.  (RV32I FENCE is intentionally a NOP in
# this core, so it would not provide that proof.)
#
# Fail code = check number (24 checks); PASS = 1.
# =============================================================================
    .section .text

    .equ PTR_LSB,       0
    .equ PTR_POS_IMM,   4
    .equ PTR_NEG_IMM,   8
    .equ PTR_RETURN,   12
    .equ PTR_WARM,     16
    .equ VAL_EQ,       20
    .equ VAL_NE,       24
    .equ VAL_NEG,      28
    .equ VAL_POS,      32
    .equ STORE_ADDR,   36
    .equ STORE_DATA,   40

.macro CHECK_EQ a, b, code
    addi x31, x0, \code
    beq  \a, \b, 1f
    beq  x0, x0, finish
1:
.endm

# Load in slot 0, branch in slot 1.  LOADREG may be either branch operand.
.macro LD_BRANCH_TAKEN insn, loadreg, off, rs1, rs2, code
    addi   x31, x0, \code
    .balign 8
    lw     \loadreg, \off(x21)
    \insn  \rs1, \rs2, 1f
    beq    x0, x0, finish
1:
.endm

.macro LD_BRANCH_NOT_TAKEN insn, loadreg, off, rs1, rs2, code
    addi   x31, x0, \code
    .balign 8
    lw     \loadreg, \off(x21)
    \insn  \rs1, \rs2, 1f
    beq    x0, x0, 2f
1:
    beq    x0, x0, finish
2:
.endm

    .globl _start
_start:
    # ---------------------------------------------------------------------
    # Build the RAM-resident test table at byte address 256.
    # ---------------------------------------------------------------------
    addi x20, x0, 256

    # JALR target with bit 0 deliberately set.  JALR must clear it.
    lla  x5, jalr_lsb_target
    ori  x5, x5, 1
    sw   x5, PTR_LSB(x20)

    # The loaded bases require positive and negative JALR immediates.
    lla  x5, jalr_pos_target
    addi x5, x5, -12
    sw   x5, PTR_POS_IMM(x20)
    lla  x5, jalr_neg_target
    addi x5, x5, 12
    sw   x5, PTR_NEG_IMM(x20)

    lla  x5, loaded_return_ok
    sw   x5, PTR_RETURN(x20)
    lla  x5, warm_target
    sw   x5, PTR_WARM(x20)

    addi x5, x0, 7
    sw   x5, VAL_EQ(x20)
    addi x5, x0, 9
    sw   x5, VAL_NE(x20)
    addi x5, x0, -1
    sw   x5, VAL_NEG(x20)
    addi x5, x0, 1
    sw   x5, VAL_POS(x20)
    addi x5, x0, 512
    sw   x5, STORE_ADDR(x20)
    addi x5, x0, 0x345
    sw   x5, STORE_DATA(x20)

    # Strong-order barrier for the setup stores.  x21 still becomes 256,
    # but only after the switch load completes and its dependent ALU ops run.
    lui  x22, 0x40000
    lw   x23, 4(x22)
    andi x23, x23, 0
    add  x21, x20, x23

    # ---------------------------------------------------------------------
    # Load -> JALR: bit-0 clearing, positive imm, and negative imm.
    # Each wrong path exits with the preloaded fail code.
    # ---------------------------------------------------------------------
    addi x12, x0, 0
    addi x31, x0, 2
    .balign 8
    lw   x5, PTR_LSB(x21)
    jalr x1, x5, 0
    addi x12, x0, 1
    beq  x0, x0, finish
jalr_lsb_target:
    CHECK_EQ x12, x0, 2

    addi x31, x0, 3
    .balign 8
    lw   x5, PTR_POS_IMM(x21)
    jalr x1, x5, 12
    addi x12, x0, 1
    beq  x0, x0, finish
jalr_pos_target:
    CHECK_EQ x12, x0, 3

    addi x31, x0, 4
    .balign 8
    lw   x5, PTR_NEG_IMM(x21)
    jalr x1, x5, -12
    addi x12, x0, 1
    beq  x0, x0, finish
jalr_neg_target:
    CHECK_EQ x12, x0, 4

    # A real return whose x1 target is loaded immediately before RET.
    addi x13, x0, 0
    addi x31, x0, 5
    jal  x1, loaded_return_func
loaded_return_ok:
    addi x28, x0, 55
    CHECK_EQ x13, x28, 5

    # Run the same indirect call twice.  On the second pass the JALR redirect
    # and the taken branch at its target are warm in the predictor.
    addi x14, x0, 0
    addi x15, x0, 2
    addi x12, x0, 0
warm_call:
    addi x31, x0, 6
    .balign 8
    lw   x5, PTR_WARM(x21)
    jalr x1, x5, 0
warm_return:
    addi x15, x15, -1
    bne  x15, x0, warm_call
    addi x28, x0, 2
    CHECK_EQ x14, x28, 6
    CHECK_EQ x12, x0, 7

    # ---------------------------------------------------------------------
    # Load -> every RV32I branch, taken and not taken.  Taken cases use the
    # loaded value as rs1; not-taken cases use it as rs2, covering both EX
    # operand inputs as well as signed/unsigned comparisons.
    # ---------------------------------------------------------------------
    addi x8,  x0, 7
    addi x9,  x0, 9
    addi x10, x0, -1
    addi x11, x0, 1

    LD_BRANCH_TAKEN     beq,  x5, VAL_EQ,  x5,  x8,  8
    LD_BRANCH_NOT_TAKEN beq,  x5, VAL_EQ,  x9,  x5,  9
    LD_BRANCH_TAKEN     bne,  x5, VAL_NE,  x5,  x8, 10
    LD_BRANCH_NOT_TAKEN bne,  x5, VAL_EQ,  x8,  x5, 11
    LD_BRANCH_TAKEN     blt,  x5, VAL_NEG, x5, x11, 12
    LD_BRANCH_NOT_TAKEN blt,  x5, VAL_NEG, x11, x5, 13
    LD_BRANCH_TAKEN     bge,  x5, VAL_POS, x5, x10, 14
    LD_BRANCH_NOT_TAKEN bge,  x5, VAL_POS, x10, x5, 15
    LD_BRANCH_TAKEN     bltu, x5, VAL_POS, x5, x10, 16
    LD_BRANCH_NOT_TAKEN bltu, x5, VAL_POS, x10, x5, 17
    LD_BRANCH_TAKEN     bgeu, x5, VAL_NEG, x5, x11, 18
    LD_BRANCH_NOT_TAKEN bgeu, x5, VAL_NEG, x11, x5, 19

    # ---------------------------------------------------------------------
    # Load -> ALU on all four ALU-port operand inputs.  Each load releases
    # two dependent ALUs together: the older one selects on port0 and the
    # runner-up selects on port1 in the same cycle.  The second pair reverses
    # which source carries the loaded tag, covering p0a/p0b/p1a/p1b.
    # ---------------------------------------------------------------------
    addi x31, x0, 20
    .balign 8
    lw   x5, VAL_NE(x21)
    addi x0, x0, 0           # keep the twin consumers in one dispatch pair
    .balign 8
    add  x6, x5, x8           # oldest: port0 A, 9 + 7 = 16
    sub  x7, x9, x5           # runner-up: port1 B, 9 - 9 = 0
    addi x28, x0, 16
    CHECK_EQ x6, x28, 20
    CHECK_EQ x7, x0, 21

    addi x31, x0, 22
    .balign 8
    lw   x5, VAL_NE(x21)
    sub  x6, x9, x5           # oldest: port0 B, 9 - 9 = 0
    add  x7, x5, x8           # runner-up: port1 A, 9 + 7 = 16
    CHECK_EQ x6, x0, 22
    addi x28, x0, 16
    CHECK_EQ x7, x28, 23

    # ---------------------------------------------------------------------
    # Load -> store address, then load -> store data.
    # ---------------------------------------------------------------------
    addi x7, x0, 0x345
    addi x31, x0, 24
    .balign 8
    lw   x5, STORE_ADDR(x21)
    sw   x7, 0(x5)
    lw   x6, 0(x5)
    CHECK_EQ x6, x7, 24

    addi x6, x0, 516
    addi x31, x0, 25
    .balign 8
    lw   x5, STORE_DATA(x21)
    sw   x5, 0(x6)
    lw   x7, 0(x6)
    addi x28, x0, 0x345
    CHECK_EQ x7, x28, 25

    addi x31, x0, 1           # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)
hang:
    beq  x0, x0, hang

# Loaded-return function.  The load/JALR pair is the function's aligned hot
# pair; x13 proves that control reached the function before returning.
    .balign 8
loaded_return_func:
    addi x13, x0, 55
    .balign 8
    lw   x1, PTR_RETURN(x21)
    jalr x0, x1, 0
    beq  x0, x0, finish

# The first instruction at the indirect target is a taken branch.  Running
# warm_call twice exercises both the cold redirect and the trained path.
    .balign 8
warm_target:
    beq  x0, x0, warm_body
    addi x12, x0, 1           # wrong path must be flushed
warm_body:
    addi x14, x14, 1
    jalr x0, x1, 0
