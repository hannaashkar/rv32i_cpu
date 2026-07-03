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

#include "Vcpu_pipeline.h"
#include "Vcpu_pipeline___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"

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

    auto top = std::make_unique<Vcpu_pipeline>(ctx.get());

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

    uint64_t t = 0;  // trace timestamp (half-cycles)
    auto half_tick = [&](uint8_t clk) {
        top->clk = clk;
        top->eval();
        if (tfp) tfp->dump(t++);
    };

    // --- reset ----------------------------------------------------------
    top->switches = 0;
    top->reset = 1;
    for (int i = 0; i < 4; ++i) { half_tick(0); half_tick(1); }
    top->reset = 0;

    // --- run ------------------------------------------------------------
    int exit_code = 1;
    uint64_t cycle = 0;
    for (cycle = 0; cycle < max_cycles; ++cycle) {
        half_tick(0);
        half_tick(1);

        // Watch the MEM stage for the magic exit store.
        auto* r = top->rootp;
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
    }

    // Performance summary straight from the hardware counters (csr_file):
    // the same cycle/instret values software sees via rdcycle/rdinstret,
    // so IPC printed here matches on-core measurement exactly.
    {
        auto* r = top->rootp;
        uint64_t hw_cycles  = r->cpu_pipeline__DOT__CSR0__DOT__cycle_cnt;
        uint64_t hw_instret = r->cpu_pipeline__DOT__CSR0__DOT__instret_cnt;
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
               r->cpu_pipeline__DOT__pcF, MAGIC_EXIT_ADDR);
        exit_code = 2;
    }

    if (tfp) tfp->close();
    top->final();
    return exit_code;
}
