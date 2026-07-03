# =============================================================================
# npu_ordering.S — directed test for BUGLOG B011 (NPU EX-hold operand decay)
# and the NPU ordering interlocks in general (docs/NPU.md, D014).
#
# The B011 shape: the register feeding an NPU access's address (or store
# data) is produced by the instruction IMMEDIATELY before it, while a GO
# is in flight. On the in-order core the access stalls in EX; the buggy
# core recomputed address/data from the forwarding muxes every held cycle,
# and once the producer drained out of MEM/WB the values decayed to the
# stale decode-time regfile copies — the address left region 0x5, the
# interlock self-released, and the access performed against dmem garbage.
# The fixed core snapshots address+data on the first hold cycle.
# On the OoO core the same program exercises the IO-load replay path
# (replays re-read the PRF, so it was never broken there).
#
# Fail codes: 2 = C readback wrong (address decay), 3 = A0 readback wrong
# (store-data decay), 4 = STATUS wrong after the runs.
# =============================================================================
    .section .text
    .globl _start
_start:
    lui  x5, 0x50000         # x5 = NPU base

    # A = identity (byte k of row i = 1 when k == i)
    li   x6, 0x00000001
    sw   x6, 0x10(x5)        # A0
    li   x6, 0x00000100
    sw   x6, 0x14(x5)        # A1
    li   x6, 0x00010000
    sw   x6, 0x18(x5)        # A2
    li   x6, 0x01000000
    sw   x6, 0x1C(x5)        # A3

    # B rows: distinct small bytes; with A = I, C[i][j] = B[i][j]
    li   x6, 0x04030201
    sw   x6, 0x20(x5)        # B0
    li   x6, 0x08070605
    sw   x6, 0x24(x5)        # B1
    li   x6, 0x0C0B0A09
    sw   x6, 0x28(x5)        # B2
    li   x6, 0x100F0E0D
    sw   x6, 0x2C(x5)        # B3

    # ---- case 1: address-producer directly before a C load, GO in flight
    addi x7, x0, 3
    sw   x7, 0x08(x5)        # CTRL = GO|CLR  -> busy for the next 10 cycles
    addi x8, x5, 0x44        # producer of the load address (B011 shape)
    lw   x9, 0(x8)           # C[0][1] — held in EX until the pass finishes
    addi x31, x0, 2          # fail code 2
    addi x10, x0, 2          # expected: C[0][1] = B[0][1] = 2
    bne  x9, x10, finish

    # ---- case 2: data-producer directly before an NPU store, GO in flight
    addi x7, x0, 1
    sw   x7, 0x08(x5)        # CTRL = GO (no clear) -> busy again
    addi x11, x0, 0x5A       # producer of the store DATA (B011 shape)
    sw   x11, 0x10(x5)       # A0 write drains only after the pass; data
    lw   x12, 0x10(x5)       #   must be the forwarded 0x5A, not stale 0
    addi x31, x0, 3          # fail code 3
    bne  x12, x11, finish

    # ---- sanity: done set, busy never observable
    lw   x13, 0x04(x5)       # STATUS
    addi x31, x0, 4          # fail code 4
    addi x14, x0, 2          # expected: done=1, busy=0
    bne  x13, x14, finish

    addi x31, x0, 1          # PASS
finish:
    lui  x1, 0x40000
    addi x1, x1, 8
    sw   x31, 0(x1)          # sim-exit store
hang:
    beq  x0, x0, hang
