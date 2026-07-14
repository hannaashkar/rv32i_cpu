#!/usr/bin/env python3
"""
gen_random_test.py -- constrained-random RV32I program generator.

Emits a ready-to-run imem hex image (no assembler needed). The programs
are self-terminating by construction -- control flow is straight-line
plus FORWARD-only branches/jumps -- and end with the magic exit store.
Correctness checking is NOT in the program: the Verilator harness runs
every instruction in lockstep against the golden-model ISS, so a test
"passes" when it reaches the exit with zero divergence.

Instruction mix (weighted): all RV32I ALU ops (R and I forms incl.
shifts), loads/stores of every size at random (possibly misaligned)
non-IO addresses, all six branches with both outcomes exercised, JAL,
the AUIPC+JALR pair, LUI/AUIPC, and Zicsr ops (mscratch + counter reads).
x0 appears as rd occasionally on purpose. Registers x28-x31 are reserved
for the exit sequence.

Usage: gen_random_test.py SEED OUT.hex [LENGTH] [--vio] [--sys] [--npu]

--vio  (D020 LQ stress) periodically inject a "late-store / early-load to the
       SAME address" pattern so the load-ordering violation CAM + poison +
       flush-at-head recovery actually fires under random interleaving. Off by
       default so the proven golden seeds are byte-identical; on it uses
       reserved scratch regs x24-x27 and is self-terminating + lockstep-safe.

--sys  inject FENCE, ECALL, EBREAK, and a reserved opcode at low weight. The
       current no-trap contract retires each as a side-effect-free NOP; the
       independent ISS checks that contract at every retirement. This is a
       separate additive lane so the proven default and --vio seed streams
       remain byte-identical.

--npu  inject adversarial NPU MMIO bursts: staged A/B writes, back-to-back GO
       commands, C/STATUS/ID/unmapped reads, and immediate-producer address/
       store-data dependencies while the array is busy. This targets the
       B010/B011 ordering/interlock space. The ISS mirrors the NPU exactly.
"""
import random
import sys

# ---------------- encoders ----------------
def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def s_type(imm, rs2, rs1, f3, op=0x23):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
         | ((imm & 0x1F) << 7) | op

def b_type(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) \
         | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
         | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63

def u_type(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def j_type(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) \
         | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) \
         | (rd << 7) | 0x6F

NOP = 0x00000013

# ---------------- generator ----------------
DATA_REGS = list(range(1, 16))          # rd/rs pool (x1..x15)
BASE_REGS = [20, 21, 22, 23]            # stable memory base registers

VIO_REGS = [24, 25, 26, 27]             # scratch regs for the --vio pattern
NPU_BASE = 19                            # stable 0x5000_0000 base (--npu)
NPU_REGS = [16, 17, 18]                  # --npu scratch; outside DATA_REGS

# Unsupported-system/decode-tail instructions. 0x0083f37f uses a reserved
# opcode with non-zero rd/rs/funct fields so an accidental partial decode is
# much more likely to become architecturally visible than an all-zero word.
SYS_NOP_WORDS = [
    0x0FF0000F,                          # FENCE iorw, iorw
    0x00000073,                          # ECALL
    0x00100073,                          # EBREAK
    0x0083F37F,                          # reserved opcode, hot operand fields
]

def gen(seed, length, vio=False, sysops=False, npu_mode=False):
    rng = random.Random(seed)
    words = []

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    # --- late-store / early-load to the SAME address (D020 LQ stress) -----
    # An OLDER store whose ADDRESS depends on a long serial chain (resolves
    # late) to the same word a YOUNGER load reads immediately: with speculative
    # loads the load issues first, reads stale, then the store fills -> the LQ
    # violation CAM fires -> poison + flush-at-head recovery. Value-agnostic:
    # lockstep vs the in-order ISS is the check (the ISS never speculates, so
    # any mis-recovery diverges at retire). Uses VIO_REGS only.
    def emit_vio(base_reg):
        b, c, s, l = VIO_REGS                     # b=addr, c=chain, s=data, l=loaded
        emit(i_type(0, base_reg, 0, b, 0x13))     # addi b, base, 0  (b = base addr)
        emit(i_type(0, 0, 0, c, 0x13))            # addi c, x0, 0     (chain = 0)
        for _ in range(rng.randrange(30, 90)):    # long serial dep chain
            emit(i_type(1, c, 0, c, 0x13))        # addi c, c, 1
        emit(r_type(0x20, c, c, 0, c, 0x33))      # sub  c, c, c   -> 0, but LATE
        emit(r_type(0, c, b, 0, b, 0x33))         # add  b, b, c   -> b, resolves LATE
        emit(i_type(rng.getrandbits(8), 0, 0, s, 0x13))   # addi s, x0, imm (store data)
        emit(s_type(0, s, b, 2))                  # sw   s, 0(b)   OLDER store (late addr)
        emit(i_type(0, base_reg, 2, l, 0x03))     # lw   l, 0(base) YOUNGER load (early)

    # --- NPU MMIO ordering/interlock stress (B010/B011) -----------------
    # Each burst has two deliberately adversarial shapes:
    #   GO; address-producer; C load    -> load must wait/replay until idle
    #   GO; data-producer; A/B store   -> held store data must not decay
    # Older staging stores + younger reads also exercise the OoO strong-order
    # rule that fixed B010. No self-check is needed: the ISS executes the NPU
    # atomically at GO, and compares every retired load/store in program order.
    def emit_npu():
        before = len(words)
        data_r, ctrl_r, addr_r = NPU_REGS
        stage_offsets = list(range(0x10, 0x20, 4)) \
                      + list(range(0x20, 0x30, 4))

        # Fill all A/B staging words with varied signed-byte patterns. Every
        # store immediately follows its producer to stress forwarding.
        for off in stage_offsets:
            emit(i_type(rng.getrandbits(12), 0, 0, data_r, 0x13))
            emit(s_type(off, data_r, NPU_BASE, 2))

        emit(i_type(3, 0, 0, ctrl_r, 0x13))        # GO | CLR
        emit(s_type(0x08, ctrl_r, NPU_BASE, 2))
        c_off = 0x40 + 4 * rng.randrange(16)
        emit(i_type(c_off, NPU_BASE, 0, addr_r, 0x13))
        emit(i_type(0, addr_r, 2, data_r, 0x03))   # held/replayed C load

        emit(i_type(1, 0, 0, ctrl_r, 0x13))        # second GO, accumulate
        emit(s_type(0x08, ctrl_r, NPU_BASE, 2))
        st_off = rng.choice(stage_offsets)
        emit(i_type(rng.getrandbits(11), 0, 0, data_r, 0x13))
        emit(s_type(st_off, data_r, NPU_BASE, 2))  # held store-data case
        emit(i_type(st_off, NPU_BASE, 2, addr_r, 0x03))  # read-after-write
        emit(i_type(0x04, NPU_BASE, 2, ctrl_r, 0x03))    # STATUS: done, !busy
        emit(i_type(0x00, NPU_BASE, 2, addr_r, 0x03))    # ID
        emit(i_type(0x30, NPU_BASE, 2, data_r, 0x03))    # unmapped -> 0
        return len(words) - before

    # --- init: seed the register pool with varied constants -----------
    for r in DATA_REGS:
        emit(u_type(rng.getrandbits(20), r, 0x37))            # lui
        emit(i_type(rng.getrandbits(11), r, 0, r, 0x13))      # addi
    # memory bases: within dmem's aliased range, far from the IO region
    for i, r in enumerate(BASE_REGS):
        emit(u_type(0x1 + i * 0x8, r, 0x37))                  # 0x1000,0x9000,...
    if npu_mode:
        emit(u_type(0x50000, NPU_BASE, 0x37))                 # 0x5000_0000
    emit(NOP)

    # --- random body ----------------------------------------------------
    def rnd_rd():   # x0 as destination ~1/20 of the time (must be a no-op)
        return 0 if rng.random() < 0.05 else rng.choice(DATA_REGS)
    def rnd_rs():
        return rng.choice([0] + DATA_REGS)

    body = 0
    if npu_mode:
        body += emit_npu()                       # guaranteed coverage per seed
    while body < length:
        # --vio: inject a violation-forcing pattern roughly every ~40 body
        # instrs. Additive only (default path unchanged when vio is False).
        if vio and rng.random() < 0.025:
            emit_vio(rng.choice(BASE_REGS))
            body += 12
            continue
        if npu_mode and rng.random() < 0.005:
            body += emit_npu()
            continue
        # Coverage-tail lane: short-circuiting means this consumes no PRNG
        # samples unless --sys is present, preserving every existing stream.
        if sysops and rng.random() < 0.02:
            emit(rng.choice(SYS_NOP_WORDS))
            body += 1
            continue
        k = rng.random()
        if k < 0.35:                                   # R-type ALU
            f3 = rng.randrange(8)
            f7 = 0x20 if (f3 in (0, 5) and rng.random() < 0.5) else 0
            emit(r_type(f7, rnd_rs(), rnd_rs(), f3, rnd_rd(), 0x33))
        elif k < 0.60:                                 # I-type ALU
            f3 = rng.randrange(8)
            if f3 == 1:
                imm = rng.randrange(32)                # slli shamt
            elif f3 == 5:
                imm = rng.randrange(32) | (0x400 if rng.random() < 0.5 else 0)
            else:
                imm = rng.getrandbits(12)
            emit(i_type(imm, rnd_rs(), f3, rnd_rd(), 0x13))
        elif k < 0.70:                                 # load (any size/sign)
            f3 = rng.choice([0, 1, 2, 4, 5])
            emit(i_type(rng.getrandbits(12), rng.choice(BASE_REGS),
                        f3, rnd_rd(), 0x03))
        elif k < 0.78:                                 # store (any size)
            f3 = rng.choice([0, 1, 2])
            emit(s_type(rng.getrandbits(12), rnd_rs(),
                        rng.choice(BASE_REGS), f3))
        elif k < 0.88:                                 # forward branch
            skip = rng.randrange(1, 4)                 # skip 1..3 instrs
            emit(b_type(4 * (skip + 1), rnd_rs(), rnd_rs(),
                        rng.choice([0, 1, 4, 5, 6, 7])))
            for _ in range(skip):
                f3 = rng.randrange(8)
                imm = rng.randrange(32) if f3 in (1, 5) else rng.getrandbits(12)
                emit(i_type(imm, rnd_rs(), f3, rnd_rd(), 0x13))
                body += 1
        elif k < 0.93:                                 # JAL forward
            skip = rng.randrange(1, 3)
            emit(j_type(4 * (skip + 1), rnd_rd()))
            for _ in range(skip):
                emit(NOP)
                body += 1
        elif k < 0.96:                                 # AUIPC+JALR forward
            t = rng.choice(DATA_REGS)
            emit(u_type(0, t, 0x17))                   # auipc t, 0
            emit(i_type(12, t, 0, rnd_rd(), 0x67))     # jalr rd, t, 12
            emit(NOP)                                  # skipped victim
            body += 2
        elif k < 0.98:                                 # LUI / AUIPC
            emit(u_type(rng.getrandbits(20), rnd_rd(),
                        rng.choice([0x37, 0x17])))
        else:                                          # Zicsr
            f3 = rng.choice([1, 2, 3, 5, 6, 7])
            csr = rng.choice([0x340, 0x340, 0x340,     # mscratch (writable)
                              0xC00, 0xC02, 0xC80, 0xC82])  # counters (inject)
            if csr != 0x340:
                f3 = 2                                  # counters: read-only
                rs1 = 0
            else:
                rs1 = rng.randrange(16) if f3 < 4 else rng.randrange(32)
            emit(i_type(csr, rs1, f3, rnd_rd(), 0x73))
        body += 1

    # --- exit: PASS store to the magic address --------------------------
    emit(u_type(0x40000, 31, 0x37))            # lui  x31, 0x40000
    emit(i_type(1, 0, 0, 30, 0x13))            # addi x30, x0, 1
    emit(s_type(8, 30, 31, 2))                 # sw   x30, 8(x31)
    emit(j_type(0, 0))                         # jal  x0, 0  (hang in place)
    return words

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    unknown = flags - {"--vio", "--sys", "--npu"}
    if unknown:
        sys.exit("unknown option(s): %s" % ", ".join(sorted(unknown)))
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    vio = "--vio" in flags
    sysops = "--sys" in flags
    npu_mode = "--npu" in flags
    seed = int(argv[0])
    out = argv[1]
    length = int(argv[2]) if len(argv) > 2 else 3000
    words = gen(seed, length, vio=vio, sysops=sysops, npu_mode=npu_mode)
    with open(out, "w") as f:
        f.write("// constrained-random test, seed %d, %d words\n"
                % (seed, len(words)))
        for w in words:
            f.write("%08x\n" % w)

if __name__ == "__main__":
    main()
