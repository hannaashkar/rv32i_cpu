// ============================================================================
// iss.h — RV32I + Zicsr instruction-set simulator (golden model)
//
// Purpose: lockstep co-simulation reference for the RTL cores. The harness
// steps this model once per RETIRED instruction and compares:
//   * the retired PC,
//   * the register writeback (rd + value) when one occurs,
//   * every store (address, size, full rs2 data) in program order.
// The first divergence aborts the sim with a diff dump — bugs are caught
// at the exact instruction, not a million cycles later at a failed CHECK.
//
// Fidelity notes — the model matches THIS SoC, quirks included, because
// the quirks are documented architecture (BUGLOG watch list):
//   * Memories alias: index = addr[17:2] (65536-word sim memories).
//   * MMIO loads (addr[31:28]==4) return the raw MMIO word — the dmem
//     byte/half extraction does NOT apply on the IO path.
//   * MMIO stores write the full word regardless of funct3 (LED reg).
//   * Misaligned RAM accesses follow the RTL's lane math exactly
//     (byte lane = addr[1:0], half lane = addr[1]) — no traps yet.
//   * JALR clears bit 0 of the target; unknown opcodes, ECALL/EBREAK and
//     FENCE retire as NOPs.
//   * cycle/instret CSR reads are microarchitectural (they depend on
//     pipeline timing), so the harness INJECTS the RTL's value into the
//     model at those reads — standard co-sim practice for free-running
//     counters. mscratch and everything else is fully modeled.
// ============================================================================
#ifndef RV32_ISS_H
#define RV32_ISS_H

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

class Rv32Iss {
public:
    static const uint32_t DEPTH_WORDS = 65536;      // matches SIM_BIG_MEM
    static const uint32_t IDX_MASK    = DEPTH_WORDS - 1;

    // Architectural state
    uint32_t x[32];
    uint32_t pc;
    uint32_t mscratch;
    uint32_t leds;                                   // MMIO LED register
    uint32_t switches;                               // MMIO switch inputs
    uint32_t imem[DEPTH_WORDS];
    uint32_t dmem[DEPTH_WORDS];

    // Result of the most recent step(), for comparison against the RTL
    struct Effect {
        uint32_t pc;             // pc of the executed instruction
        uint32_t instr;          // raw instruction (for diagnostics)
        bool     wrote_rd;       // architectural rd write (rd != x0)
        uint32_t rd;
        uint32_t rd_val;
        bool     is_store;
        uint32_t st_addr;
        uint32_t st_data;        // full rs2 value (RTL drives the full word)
        uint32_t st_funct3;
    };
    Effect eff;

    Rv32Iss() { reset(); }

    void reset() {
        memset(x, 0, sizeof(x));
        pc       = 0;
        mscratch = 0;
        leds     = 0;
        switches = 0;
        for (uint32_t i = 0; i < DEPTH_WORDS; ++i) imem[i] = 0x00000013; // NOP
        memset(dmem, 0, sizeof(dmem));
    }

    // $readmemh-style loader: one hex word per line, '//' comments allowed.
    bool load_hex(const char* path, uint32_t* mem) {
        FILE* f = fopen(path, "r");
        if (!f) return false;
        char line[128];
        uint32_t idx = 0;
        while (fgets(line, sizeof(line), f) && idx < DEPTH_WORDS) {
            char* p = line;
            while (*p == ' ' || *p == '\t') ++p;
            if (*p == '\n' || *p == '\0' || (p[0] == '/' && p[1] == '/'))
                continue;
            mem[idx++] = (uint32_t)strtoul(p, nullptr, 16);
        }
        fclose(f);
        return true;
    }

    static bool is_io(uint32_t addr) { return (addr >> 28) == 0x4; }

    uint32_t mmio_read(uint32_t addr) const {
        if (addr == 0x40000000u) return leds & 0x3FF;
        if (addr == 0x40000004u) return switches & 0x3FF;
        return 0;
    }

    // Execute one instruction. csr_inject supplies the RTL's writeback
    // value, adopted only for cycle/instret CSR reads (see header).
    void step(uint32_t csr_inject) {
        const uint32_t instr = imem[(pc >> 2) & IDX_MASK];
        eff = Effect();
        eff.pc    = pc;
        eff.instr = instr;

        const uint32_t opcode = instr & 0x7F;
        const uint32_t rd     = (instr >> 7)  & 0x1F;
        const uint32_t funct3 = (instr >> 12) & 0x7;
        const uint32_t rs1    = (instr >> 15) & 0x1F;
        const uint32_t rs2    = (instr >> 20) & 0x1F;
        const uint32_t funct7 = (instr >> 25) & 0x7F;
        const uint32_t a = x[rs1], b = x[rs2];

        const int32_t imm_i = (int32_t)instr >> 20;
        const int32_t imm_s = ((int32_t)(instr & 0xFE000000) >> 20)
                              | (int32_t)((instr >> 7) & 0x1F);
        const int32_t imm_b = (((int32_t)instr >> 31) << 12)
                              | (int32_t)(((instr >> 7) & 1) << 11)
                              | (int32_t)(((instr >> 25) & 0x3F) << 5)
                              | (int32_t)(((instr >> 8) & 0xF) << 1);
        const int32_t imm_u = (int32_t)(instr & 0xFFFFF000);
        const int32_t imm_j = (((int32_t)instr >> 31) << 20)
                              | (int32_t)(((instr >> 12) & 0xFF) << 12)
                              | (int32_t)(((instr >> 20) & 1) << 11)
                              | (int32_t)(((instr >> 21) & 0x3FF) << 1);

        uint32_t next_pc = pc + 4;

        switch (opcode) {
        case 0x33: { // R-type ALU
            uint32_t r = 0;
            const uint32_t sh = b & 0x1F;
            switch (funct3) {
            case 0: r = (funct7 & 0x20) ? a - b : a + b;             break;
            case 1: r = a << sh;                                     break;
            case 2: r = ((int32_t)a < (int32_t)b) ? 1 : 0;           break;
            case 3: r = (a < b) ? 1 : 0;                             break;
            case 4: r = a ^ b;                                       break;
            case 5: r = (funct7 & 0x20) ? (uint32_t)((int32_t)a >> sh)
                                        : a >> sh;                   break;
            case 6: r = a | b;                                       break;
            case 7: r = a & b;                                       break;
            }
            write_rd(rd, r);
            break;
        }
        case 0x13: { // I-type ALU
            uint32_t r = 0;
            const uint32_t sh = imm_i & 0x1F;
            switch (funct3) {
            case 0: r = a + (uint32_t)imm_i;                         break;
            case 1: r = a << sh;                                     break;
            case 2: r = ((int32_t)a < imm_i) ? 1 : 0;                break;
            case 3: r = (a < (uint32_t)imm_i) ? 1 : 0;               break;
            case 4: r = a ^ (uint32_t)imm_i;                         break;
            case 5: r = (instr & 0x40000000) ? (uint32_t)((int32_t)a >> sh)
                                             : a >> sh;              break;
            case 6: r = a | (uint32_t)imm_i;                         break;
            case 7: r = a & (uint32_t)imm_i;                         break;
            }
            write_rd(rd, r);
            break;
        }
        case 0x03: { // loads
            const uint32_t addr = a + (uint32_t)imm_i;
            uint32_t val;
            if (is_io(addr)) {
                val = mmio_read(addr);       // raw word: no lane extraction
            } else {
                const uint32_t word  = dmem[(addr >> 2) & IDX_MASK];
                const uint32_t byte_ = (word >> ((addr & 3) * 8)) & 0xFF;
                const uint32_t half  = (word >> (((addr >> 1) & 1) * 16))
                                       & 0xFFFF;
                switch (funct3) {
                case 0:  val = (uint32_t)(int32_t)(int8_t)byte_;   break;
                case 1:  val = (uint32_t)(int32_t)(int16_t)half;   break;
                case 4:  val = byte_;                              break;
                case 5:  val = half;                               break;
                default: val = word;                               break;
                }
            }
            write_rd(rd, val);
            break;
        }
        case 0x23: { // stores
            const uint32_t addr = a + (uint32_t)imm_s;
            eff.is_store  = true;
            eff.st_addr   = addr;
            eff.st_data   = b;
            eff.st_funct3 = funct3;
            if (is_io(addr)) {
                if (addr == 0x40000000u) leds = b & 0x3FF; // full word, any size
            } else {
                const uint32_t idx = (addr >> 2) & IDX_MASK;
                switch (funct3 & 3) {
                case 0: {
                    const uint32_t sh = (addr & 3) * 8;
                    dmem[idx] = (dmem[idx] & ~(0xFFu << sh))
                                | ((b & 0xFF) << sh);
                    break;
                }
                case 1: {
                    const uint32_t sh = ((addr >> 1) & 1) * 16;
                    dmem[idx] = (dmem[idx] & ~(0xFFFFu << sh))
                                | ((b & 0xFFFF) << sh);
                    break;
                }
                default: dmem[idx] = b; break;
                }
            }
            break;
        }
        case 0x63: { // branches
            bool taken = false;
            switch (funct3) {
            case 0: taken = (a == b);                       break;
            case 1: taken = (a != b);                       break;
            case 4: taken = ((int32_t)a <  (int32_t)b);     break;
            case 5: taken = ((int32_t)a >= (int32_t)b);     break;
            case 6: taken = (a <  b);                       break;
            case 7: taken = (a >= b);                       break;
            default: taken = false;                         break;
            }
            if (taken) next_pc = pc + (uint32_t)imm_b;
            break;
        }
        case 0x37: write_rd(rd, (uint32_t)imm_u);           break; // LUI
        case 0x17: write_rd(rd, pc + (uint32_t)imm_u);      break; // AUIPC
        case 0x6F: // JAL
            write_rd(rd, pc + 4);
            next_pc = pc + (uint32_t)imm_j;
            break;
        case 0x67: // JALR
            write_rd(rd, pc + 4);
            next_pc = (a + (uint32_t)imm_i) & ~1u;
            break;
        case 0x73: { // SYSTEM: Zicsr (funct3!=0); ECALL/EBREAK = NOP
            if (funct3 != 0) {
                const uint32_t csr = (instr >> 20) & 0xFFF;
                uint32_t old;
                bool injected = false;
                switch (csr) {
                case 0xC00: case 0xC80:            // cycle/cycleh
                case 0xC02: case 0xC82:            // instret/instreth
                    old = csr_inject; injected = true; break;
                case 0x340: old = mscratch;        break;
                default:    old = 0;               break;
                }
                (void)injected;
                const uint32_t operand = (funct3 & 4) ? rs1 : a;
                const bool is_rw = ((funct3 & 3) == 1);
                const bool wreq  = is_rw || (rs1 != 0);
                uint32_t wdata = operand;
                if ((funct3 & 3) == 2) wdata = old | operand;
                if ((funct3 & 3) == 3) wdata = old & ~operand;
                if (wreq && csr == 0x340) mscratch = wdata;
                write_rd(rd, old);
            }
            break;
        }
        default: break; // FENCE, unknown opcodes: NOP
        }

        pc = next_pc;
        x[0] = 0;
    }

private:
    void write_rd(uint32_t rd, uint32_t val) {
        if (rd != 0) {
            x[rd] = val;
            eff.wrote_rd = true;
            eff.rd       = rd;
            eff.rd_val   = val;
        }
    }
};

#endif // RV32_ISS_H
