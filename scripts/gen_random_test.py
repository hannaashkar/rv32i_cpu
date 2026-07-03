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

Usage: gen_random_test.py SEED OUT.hex [LENGTH]
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

def gen(seed, length):
    rng = random.Random(seed)
    words = []

    def emit(w):
        words.append(w & 0xFFFFFFFF)

    # --- init: seed the register pool with varied constants -----------
    for r in DATA_REGS:
        emit(u_type(rng.getrandbits(20), r, 0x37))            # lui
        emit(i_type(rng.getrandbits(11), r, 0, r, 0x13))      # addi
    # memory bases: within dmem's aliased range, far from the IO region
    for i, r in enumerate(BASE_REGS):
        emit(u_type(0x1 + i * 0x8, r, 0x37))                  # 0x1000,0x9000,...
    emit(NOP)

    # --- random body ----------------------------------------------------
    def rnd_rd():   # x0 as destination ~1/20 of the time (must be a no-op)
        return 0 if rng.random() < 0.05 else rng.choice(DATA_REGS)
    def rnd_rs():
        return rng.choice([0] + DATA_REGS)

    body = 0
    while body < length:
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
    seed = int(sys.argv[1])
    out = sys.argv[2]
    length = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    words = gen(seed, length)
    with open(out, "w") as f:
        f.write("// constrained-random test, seed %d, %d words\n"
                % (seed, len(words)))
        for w in words:
            f.write("%08x\n" % w)

if __name__ == "__main__":
    main()
