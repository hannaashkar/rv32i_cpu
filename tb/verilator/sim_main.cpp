// ============================================================================
// sim_main.cpp — Verilator harness for cpu_pipeline
//
// Loads a program into imem and runs until the program signals completion,
// then reports PASS/FAIL and exits with a matching process exit code (so
// `make test` and future CI can chain on it).
//
// Test-end protocol (see CLAUDE.md):
//   The program stores a word to MAGIC_EXIT_ADDR (0x40000008, inside the
//   MMIO region so real hardware simply ignores it):
//       value == 1  ->  PASS            (exit code 0)
//       value != 1  ->  FAIL <value>    (exit code 1)
//   The harness watches the MEM-stage store bus via signals marked
//   /*verilator public_flat_rd*/ in cpu_pipeline.v.
//
// Runtime arguments (all optional except +imem):
//   +imem=<file.hex>    program to load (one 32-bit hex word per line)
//   +max_cycles=<N>     hang guard, default 100000
//   +trace              dump FST waveform to sim.fst (Surfer / GTKWave)
// ============================================================================
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <deque>

// Two cores share this harness: the in-order cpu_pipeline (default) and
// the 2-wide OoO ooo_cpu (-DOOO_TOP, built into obj_dir_ooo). The OoO
// core retires up to two instructions per cycle and commits stores from
// its store queue with a delay, so its lockstep uses a two-FIFO stream
// compare instead of the in-order core's queue-at-MEM scheme.
#ifdef OOO_TOP
#include "Vooo_cpu.h"
#include "Vooo_cpu___024root.h"
typedef Vooo_cpu TopModel;
#define CORE(x) (r->ooo_cpu__DOT__##x)
#else
#include "Vcpu_pipeline.h"
#include "Vcpu_pipeline___024root.h"
typedef Vcpu_pipeline TopModel;
#define CORE(x) (r->cpu_pipeline__DOT__##x)
#endif
#include "verilated.h"
#include "verilated_fst_c.h"

#include "iss.h"

static const uint32_t MAGIC_EXIT_ADDR = 0x40000008u;
// Sim console: any byte stored here is printed to stdout (ee_printf's
// backend). mmio.v ignores the address, so programs run unmodified on HW.
static const uint32_t MAGIC_PUTC_ADDR = 0x40000010u;

// Legacy Verilator time hook. Declared weak in verilated.cpp, but MinGW's
// linker does not resolve weak externals, so provide it explicitly.
double sc_time_stamp() { return 0.0; }

int main(int argc, char** argv) {
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(argc, argv);

    auto top = std::make_unique<TopModel>(ctx.get());

    // --- runtime options -----------------------------------------------
    uint64_t max_cycles = 100000;
    {
        const char* arg = ctx->commandArgsPlusMatch("max_cycles=");
        if (arg && arg[0])
            max_cycles = strtoull(arg + strlen("+max_cycles="), nullptr, 0);
    }

    std::unique_ptr<VerilatedFstC> tfp;
    {
        const char* arg = ctx->commandArgsPlusMatch("trace");
        if (arg && arg[0]) {
            ctx->traceEverOn(true);
            tfp = std::make_unique<VerilatedFstC>();
            top->trace(tfp.get(), 99);
            tfp->open("sim.fst");
            printf("[sim] tracing to sim.fst\n");
        }
    }

    bool verbose = false;
    {
        const char* arg = ctx->commandArgsPlusMatch("verbose");
        if (arg && arg[0]) verbose = true;
    }

    // --- golden-model lockstep ------------------------------------------
    // Default ON whenever a program is loaded via +imem; +nolockstep
    // disables it (e.g. for programs that intentionally diverge).
    // Every retired instruction is compared against the ISS: retired pc,
    // register writeback, and each store in program order.
    auto iss = std::make_unique<Rv32Iss>();
    bool lockstep = false;
    {
        std::string imem_path, dmem_path;
        const char* arg = ctx->commandArgsPlusMatch("imem=");
        if (arg && arg[0]) imem_path = arg + strlen("+imem=");
        arg = ctx->commandArgsPlusMatch("dmem=");
        if (arg && arg[0]) dmem_path = arg + strlen("+dmem=");
        const char* off = ctx->commandArgsPlusMatch("nolockstep");
        if (!imem_path.empty() && !(off && off[0])) {
            if (!iss->load_hex(imem_path.c_str(), iss->imem)) {
                printf("[lockstep] cannot read %s\n", imem_path.c_str());
                return 1;
            }
            if (!dmem_path.empty()
                && !iss->load_hex(dmem_path.c_str(), iss->dmem)) {
                printf("[lockstep] cannot read %s\n", dmem_path.c_str());
                return 1;
            }
            lockstep = true;
        }
    }
    struct StoreEvt { uint32_t addr, data, funct3; };
    std::deque<StoreEvt> rtl_stores;
    std::deque<StoreEvt> iss_stores;   // OoO: stream-compared vs commits
    uint64_t compared = 0;

    uint64_t t = 0;  // trace timestamp (half-cycles)
    auto half_tick = [&](uint8_t clk) {
        top->clk = clk;
        top->eval();
        if (tfp) tfp->dump(t++);
    };

    // --- reset ----------------------------------------------------------
    // +sw=<n> drives the board switches (D023: the MLP board demo selects
    // its test image on SW[2:0]). The ISS mirrors the same value so
    // switch-dependent programs stay lockstep-comparable.
    uint32_t sw_val = 0;
    {
        const char* arg = ctx->commandArgsPlusMatch("sw=");
        if (arg && arg[0]) sw_val = (uint32_t)strtoul(arg + 4, nullptr, 0);
    }
    top->switches = sw_val & 0x3FF;
    iss->switches = sw_val & 0x3FF;
    top->reset = 1;
    for (int i = 0; i < 4; ++i) { half_tick(0); half_tick(1); }
    top->reset = 0;

    // --- run ------------------------------------------------------------
    int exit_code = 1;
    uint64_t cycle = 0;
    for (cycle = 0; cycle < max_cycles; ++cycle) {
        half_tick(0);
        half_tick(1);

        auto* r = top->rootp;

#ifdef OOO_TOP
        // ---- OoO core: snoop the SQ commit port ------------------------
        // mw_fire = mw_valid && mw_ready: with the NPU drain backpressure
        // (D014) a held store keeps mw_valid asserted for several cycles,
        // so snooping mw_valid would duplicate store events.
        if (CORE(mw_fire)) {
            if (CORE(mw_addr) == MAGIC_PUTC_ADDR) {
                putchar((int)(CORE(mw_data) & 0xFF));
                fflush(stdout);
            }
            if (lockstep)   // magic stores compared too — ISS emits them
                rtl_stores.push_back({CORE(mw_addr), CORE(mw_data),
                                      CORE(mw_f3)});
        }

        if (lockstep) {
            for (int slot = 0; slot < 2; ++slot) {
                const bool     v    = slot ? CORE(ret1_v)   : CORE(ret0_v);
                if (!v) break;
                const uint32_t rpc  = slot ? CORE(ret1_pc)  : CORE(ret0_pc);
                const uint32_t rrd  = slot ? CORE(ret1_rd)  : CORE(ret0_rd);
                const uint32_t rval = slot ? CORE(ret1_val) : CORE(ret0_val);
                const bool     rwr  = (slot ? CORE(ret1_wr) : CORE(ret0_wr))
                                      && rrd != 0;
                iss->step(rval);
                const auto& e = iss->eff;
                bool bad = false;
                if (rpc != e.pc) bad = true;
                if (rwr != e.wrote_rd) bad = true;
                if (rwr && e.wrote_rd && (rrd != e.rd || rval != e.rd_val))
                    bad = true;
                if (e.is_store)
                    iss_stores.push_back({e.st_addr, e.st_data,
                                          e.st_funct3});
                if (bad) {
                    printf("\n[lockstep] MISMATCH at cycle %llu slot %d "
                           "(%llu instructions compared)\n",
                           (unsigned long long)cycle, slot,
                           (unsigned long long)compared);
                    printf("  RTL: pc=0x%08x rd=x%u wr=%d val=0x%08x\n",
                           rpc, rrd, (int)rwr, rval);
                    printf("  ISS: pc=0x%08x rd=x%u wr=%d val=0x%08x "
                           "instr=0x%08x\n",
                           e.pc, e.rd, (int)e.wrote_rd, e.rd_val, e.instr);
                    if (tfp) tfp->close();
                    top->final();
                    return 3;
                }
                ++compared;
            }
            // drain matching store pairs (commit lags retire; two FIFOs
            // absorb the skew)
            while (!rtl_stores.empty() && !iss_stores.empty()) {
                const StoreEvt a = rtl_stores.front(); rtl_stores.pop_front();
                const StoreEvt b = iss_stores.front(); iss_stores.pop_front();
                if (a.addr != b.addr || a.data != b.data
                    || (a.funct3 & 3) != (b.funct3 & 3)) {
                    printf("\n[lockstep] STORE MISMATCH at cycle %llu "
                           "(%llu instructions compared)\n",
                           (unsigned long long)cycle,
                           (unsigned long long)compared);
                    printf("  RTL: [0x%08x] <= 0x%08x (f3=%u)\n",
                           a.addr, a.data, a.funct3);
                    printf("  ISS: [0x%08x] <= 0x%08x (f3=%u)\n",
                           b.addr, b.data, b.funct3);
                    if (tfp) tfp->close();
                    top->final();
                    return 3;
                }
            }
        }

        if (CORE(mw_fire) && CORE(mw_addr) == MAGIC_EXIT_ADDR) {
            uint32_t code = CORE(mw_data);
            if (code == 1) {
                printf("[sim] PASS after %llu cycles\n",
                       (unsigned long long)cycle);
                exit_code = 0;
            } else {
                printf("[sim] FAIL (code %u) after %llu cycles\n",
                       code, (unsigned long long)cycle);
                exit_code = 1;
            }
            break;
        }
#else
        // ---- in-order core --------------------------------------------
        if (verbose && r->cpu_pipeline__DOT__BranchE)
            printf("[sim] cycle %llu: branch pcE=0x%08x rs1=0x%08x rs2=0x%08x "
                   "zero=%d mispredict=%d\n",
                   (unsigned long long)cycle,
                   r->cpu_pipeline__DOT__pcE,
                   r->cpu_pipeline__DOT__rs1_fwdE,
                   r->cpu_pipeline__DOT__rs2_fwd_base,
                   (int)r->cpu_pipeline__DOT__alu_zeroE,
                   (int)r->cpu_pipeline__DOT__mispredictE);
        if (verbose && r->cpu_pipeline__DOT__BranchE)
            printf("[sim]      WB: rdW=x%d RegWriteW=%d MemToRegW=%d "
                   "mem_dataW=0x%08x resultW=0x%08x fwdA=%d\n",
                   (int)r->cpu_pipeline__DOT__rdW,
                   (int)r->cpu_pipeline__DOT__RegWriteW,
                   (int)r->cpu_pipeline__DOT__MemToRegW,
                   r->cpu_pipeline__DOT__mem_dataW,
                   r->cpu_pipeline__DOT__resultW,
                   (int)r->cpu_pipeline__DOT__forwardAE);
        if (verbose && r->cpu_pipeline__DOT__MemWriteM)
            printf("[sim] cycle %llu: store [0x%08x] <= 0x%08x (pc=0x%08x)\n",
                   (unsigned long long)cycle,
                   r->cpu_pipeline__DOT__alu_resultM,
                   r->cpu_pipeline__DOT__rs2_dataM,
                   r->cpu_pipeline__DOT__pcF);
        if (r->cpu_pipeline__DOT__MemWriteM &&
            r->cpu_pipeline__DOT__alu_resultM == MAGIC_PUTC_ADDR) {
            putchar((int)(r->cpu_pipeline__DOT__rs2_dataM & 0xFF));
            fflush(stdout);
        }

        // Lockstep: queue stores as they appear in MEM (one cycle before
        // that instruction retires), then compare at retirement.
        if (lockstep) {
            if (r->cpu_pipeline__DOT__MemWriteM) {
                rtl_stores.push_back({r->cpu_pipeline__DOT__alu_resultM,
                                      r->cpu_pipeline__DOT__rs2_dataM,
                                      r->cpu_pipeline__DOT__funct3M});
            }
            if (r->cpu_pipeline__DOT__validW) {
                const uint32_t rtl_pc = r->cpu_pipeline__DOT__pcW;
                iss->step(r->cpu_pipeline__DOT__resultW);
                const auto& e = iss->eff;
                const bool rtl_wr = r->cpu_pipeline__DOT__RegWriteW
                                    && r->cpu_pipeline__DOT__rdW != 0;
                bool bad = false;
                if (rtl_pc != e.pc) bad = true;
                if (rtl_wr != e.wrote_rd) bad = true;
                if (rtl_wr && e.wrote_rd
                    && (r->cpu_pipeline__DOT__rdW != e.rd
                        || r->cpu_pipeline__DOT__resultW != e.rd_val))
                    bad = true;
                if (e.is_store) {
                    if (rtl_stores.empty()) {
                        bad = true;
                    } else {
                        const StoreEvt s = rtl_stores.front();
                        rtl_stores.pop_front();
                        if (s.addr != e.st_addr || s.data != e.st_data
                            || (s.funct3 & 3) != (e.st_funct3 & 3))
                            bad = true;
                    }
                }
                if (bad) {
                    printf("\n[lockstep] MISMATCH at cycle %llu "
                           "(%llu instructions compared)\n",
                           (unsigned long long)cycle,
                           (unsigned long long)compared);
                    printf("  RTL: pc=0x%08x rd=x%u wr=%d val=0x%08x\n",
                           rtl_pc, (unsigned)r->cpu_pipeline__DOT__rdW,
                           (int)rtl_wr, r->cpu_pipeline__DOT__resultW);
                    printf("  ISS: pc=0x%08x rd=x%u wr=%d val=0x%08x "
                           "instr=0x%08x\n",
                           e.pc, e.rd, (int)e.wrote_rd, e.rd_val, e.instr);
                    if (e.is_store)
                        printf("  ISS store: [0x%08x] <= 0x%08x (f3=%u)\n",
                               e.st_addr, e.st_data, e.st_funct3);
                    if (tfp) tfp->close();
                    top->final();
                    return 3;
                }
                ++compared;
            }
        }
        if (r->cpu_pipeline__DOT__MemWriteM &&
            r->cpu_pipeline__DOT__alu_resultM == MAGIC_EXIT_ADDR) {
            uint32_t code = r->cpu_pipeline__DOT__rs2_dataM;
            if (code == 1) {
                printf("[sim] PASS after %llu cycles\n",
                       (unsigned long long)cycle);
                exit_code = 0;
            } else {
                printf("[sim] FAIL (code %u) after %llu cycles\n",
                       code, (unsigned long long)cycle);
                exit_code = 1;
            }
            break;
        }
#endif
    }

    if (lockstep)
        printf("[lockstep] %llu instructions compared against the golden "
               "model, no divergence\n", (unsigned long long)compared);

    // Performance summary straight from the hardware counters (csr_file):
    // the same cycle/instret values software sees via rdcycle/rdinstret,
    // so IPC printed here matches on-core measurement exactly.
    {
        auto* r = top->rootp;
        uint64_t hw_cycles  = CORE(CSR0__DOT__cycle_cnt);
        uint64_t hw_instret = CORE(CSR0__DOT__instret_cnt);
        printf("[sim] perf: cycles=%llu instret=%llu ipc=%.3f\n",
               (unsigned long long)hw_cycles,
               (unsigned long long)hw_instret,
               hw_cycles ? (double)hw_instret / (double)hw_cycles : 0.0);
    }

    if (cycle >= max_cycles) {
        auto* r = top->rootp;
        printf("[sim] TIMEOUT after %llu cycles (pc=0x%08x) — "
               "no store to 0x%08x seen\n",
               (unsigned long long)max_cycles,
               CORE(pcF), MAGIC_EXIT_ADDR);
        exit_code = 2;
    }

    if (tfp) tfp->close();
    top->final();
    return exit_code;
}
