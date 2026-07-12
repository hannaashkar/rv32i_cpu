# =============================================================================
# hex_mmio.S — 7-segment display MMIO registers (D023)
#
# Exercises the two HEX registers in rtl/soc/mmio.v:
#   0x4000000C HEXLO {HEX3..HEX0}   full 32-bit R/W
#   0x40000014 HEXHI {HEX5,HEX4}    low 16 bits R/W, high half reads 0
#
# Checks, all also lockstep-compared against the ISS mirror (iss.h):
#   1. reset values read back all-ones (every segment dark, active-low)
#   2. written patterns read back exactly
#   3. HEXHI write drops wdata[31:16] (reads back zero-extended)
#   4. neighboring registers are untouched by HEX writes (LEDs still 0)
#   5. back-to-back write->read (store-to-load through the IO ordering path)
# =============================================================================
    .section .text
    .globl _start
_start:
    lui  x1, 0x40000          # MMIO base

    # ---- 1. reset values -------------------------------------------------
    lw   x5, 12(x1)           # HEXLO
    li   x6, 0xFFFFFFFF
    bne  x5, x6, fail2
    lw   x5, 20(x1)           # HEXHI
    li   x6, 0x0000FFFF
    bne  x5, x6, fail3

    # ---- 2. write / read back -------------------------------------------
    li   x7, 0x12345678
    sw   x7, 12(x1)
    lw   x5, 12(x1)
    bne  x5, x7, fail4

    # ---- 3. HEXHI keeps only [15:0] ---------------------------------------
    li   x7, 0xABCD9024
    sw   x7, 20(x1)
    lw   x5, 20(x1)
    li   x6, 0x00009024
    bne  x5, x6, fail5

    # ---- 4. LEDs untouched by the HEX writes ------------------------------
    lw   x5, 0(x1)
    bne  x5, x0, fail6

    # ---- 5. back-to-back write->read, then flip to a second pattern -------
    li   x7, 0xC0F9A4B0       # font bytes for 0,1,2,3
    sw   x7, 12(x1)
    lw   x5, 12(x1)
    bne  x5, x7, fail7
    li   x7, 0x999282F8       # font bytes for 4,5,6,7
    sw   x7, 12(x1)
    lw   x5, 12(x1)
    bne  x5, x7, fail8

    addi x31, x0, 1           # PASS
    j    finish
fail2:
    addi x31, x0, 2
    j    finish
fail3:
    addi x31, x0, 3
    j    finish
fail4:
    addi x31, x0, 4
    j    finish
fail5:
    addi x31, x0, 5
    j    finish
fail6:
    addi x31, x0, 6
    j    finish
fail7:
    addi x31, x0, 7
    j    finish
fail8:
    addi x31, x0, 8
finish:
    sw   x31, 8(x1)           # test-end protocol
hang:
    beq  x0, x0, hang
