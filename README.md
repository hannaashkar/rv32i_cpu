<p align="center">
  <img src="https://img.shields.io/badge/RISC--V-RV32I_+_Zicsr-brightgreen?style=for-the-badge&logo=riscv" />
  <img src="https://img.shields.io/badge/Core-2--wide_Out--of--Order-orange?style=for-the-badge" />
  <img src="https://img.shields.io/badge/NPU-4×4_int8_Systolic-red?style=for-the-badge" />
  <img src="https://img.shields.io/badge/FPGA-DE10--Lite_(MAX_10)-blue?style=for-the-badge&logo=intel" />
</p>

# RISC-V SoC — from a 5-stage core to an out-of-order CPU with an AI accelerator, running on real hardware

**Hanna Ashkar** · Electrical Engineering, Technion · Digital Design / Computer Architecture / RISC-V

A RISC-V **RV32I + Zicsr** system-on-chip built and measured in stages: a
classic 5-stage in-order pipeline, upgraded into a **2-wide out-of-order
superscalar** with register renaming, speculative loads and a **store-set
memory-dependence predictor**, extended with a tightly-coupled **4×4 int8
systolic-array NPU** that runs a real quantized MNIST neural network — and
brought up on an FPGA, where it **boots standalone from on-chip flash**.
Every stage is **benchmarked, golden-model-verified, and reproducible** —
measurement matters as much as the RTL.

https://github.com/user-attachments/assets/236d160b-ccb6-4e1c-92c8-c92e5c0e4397

---

## 📊 Results at a glance

| Stage | What it is | Headline number |
|---|---|---|
| **In-order baseline** (`v1.0`) | Classic 5-stage, forwarding, branch prediction | **1.177 CoreMark/MHz**, IPC 0.849 |
| **Out-of-order core** (`v2.0`) | 2-wide, renaming, ROB, speculation + recovery | **1.397 CoreMark/MHz (+18.8%)**, IPC 1.008 |
| **NPU + MNIST MLP** (`v3.0`) | 4×4 int8 systolic array, quantized 784→32→10 net | **86× inference speedup** (in-order; 56× vs the faster OoO software path), 97.1% accuracy |
| **FPGA bring-up** (`v3.1`) | PLL + SDC timing closure, block-RAM memories | In-order core **meets 50 MHz** on the DE10-Lite |
| **OoO on hardware** | Issue-queue select restructured (2.33× Fmax), M9K program ROM | OoO + NPU + predictor **live at 16.67 MHz**, boots from flash |
| **Speculative loads** | 8-entry load queue + store-set predictor (ISCA '98) | CoreMark **IPC 1.026**, pathological regression 90% recovered |
| **Verification** | Golden-model lockstep co-sim + random + ISA suite | **14 bugs** found & documented, 0 divergence |

Performance numbers are from **cycle-accurate simulation** using the core's
own hardware performance counters, CRC-validated where applicable, and
reproducible with the commands below; FPGA results are **fitter/STA reports
and live hardware**. Full methodology in
[`docs/BASELINE.md`](docs/BASELINE.md).

---

## 🧩 What's inside

### 1. In-order core — the baseline (`rtl/core/`)
Classic 5-stage pipeline (IF → ID → EX → MEM → WB) with full forwarding
(EX←MEM, EX←WB, store-data, register write→read bypass), load-use
interlock, a 64-entry 2-bit BHT + tagged BTB, and byte/half/word memory.
Complete RV32I user-level ISA plus Zicsr counters (cycle/instret) for
self-measurement. Runs compiled C and the full CoreMark benchmark —
and meets **50 MHz** on the FPGA (STA Fmax 53.95 MHz).

### 2. Out-of-order core — the upgrade (`rtl/ooo/`, [`docs/OOO.md`](docs/OOO.md))
A 2-wide out-of-order superscalar that runs the **identical binary** as the
baseline, +18.8% faster per clock:
- **Register renaming** — R10K-style merged physical register file (64
  registers), RAT + free list
- **32-entry ROB**, 2-wide dispatch/retire; **16-entry unified issue queue**
  whose select logic was restructured from a serial scan into a balanced
  log-depth tree — **2.33× Fmax** at bit-identical IPC, proven by lockstep
  ([`docs/DECISIONS.md`](docs/DECISIONS.md) D019)
- **Speculative execution with full recovery** — gshare (1024) + BTB (64) +
  RAS (8), 8 per-branch RAT checkpoints, single-cycle mispredict restore
- **Speculative loads** — 8-entry store queue with store-to-load forwarding
  + 8-entry load queue with a violation CAM and flush-at-head repair
  ([`docs/LQ.md`](docs/LQ.md)), governed by a **store-set
  memory-dependence predictor** (Chrysos & Emer, ISCA '98 — measured
  against the Alpha 21264's 1-bit scheme and beating it by 12.7% on a
  pointer-chase microbenchmark; [`docs/STORESET.md`](docs/STORESET.md))

### 3. NPU — the accelerator (`rtl/npu/`, [`docs/NPU.md`](docs/NPU.md))
A 4×4 **output-stationary systolic array** of int8 MAC units, memory-mapped
so both cores can drive it, mapping to **16 hardware multipliers** on the
FPGA. It runs a **quantized MNIST MLP** (784→32→10, symmetric int8,
TFLite-style requantization) at **97.1% accuracy** — and the same network
runs **86× faster** on the array than in software on the in-order core
(56× against the OoO core's faster software path). Correctness is
proven **bit-exact** against the software path, and the memory-ordering
between CPU and accelerator is enforced in hardware (no software polling).

### 4. On silicon — where simulation meets physics ([`docs/DEMO.md`](docs/DEMO.md))
The best lesson in the project: **wall-clock performance = IPC × Fmax.**
The OoO core's first board port won +18.8% IPC but managed only 8.42 MHz —
the un-pipelined issue-queue select+wakeup was a ~118 ns critical path —
making it ~6× *slower* than the in-order core on the same chip. Rewriting
the selection logic as a balanced log-depth tree raised Fmax 2.33× with
**bit-identical** cycle behavior (proven by lockstep), and the board now
runs the full OoO SoC at 16.67 MHz. Along the way: a three-session mystery
("MIF is not supported for the selected family") turned out to be **one
missing QSF line** — MAX 10 needs an ERAM-capable configuration mode to
initialize block RAM — unlocking M9K-resident program and data memories.
The CPU **boots standalone from internal flash** (verified on the board
with the bring-up program); the same mechanism puts the MNIST demo's
program *and neural-net weights* into block RAM at power-up — there is no
loader, the weights are simply there. The MNIST demo (RTL + software
complete, self-test lockstep-verified on both cores, 8/8 images correct;
board bitstream now **builds and closes timing** — the gshare-predictor
M9K shrink (D024) freed the fabric, the demo top fits at 88% LEs with
+16.8 ns slack, and the `.sof` is built; the on-silicon flash is the
remaining step): flip three switches to pick a handwritten
digit, the 7-segment displays show the true label next to the network's
answer — ~3 ms per inference at the 16.67 MHz board clock
(simulation-measured), with the OoO core finishing the same work in
**1.83× fewer cycles** than the in-order core.

---

## 🧪 Verification — the part that makes it real

The whole SoC is checked by **golden-model lockstep co-simulation**: an
independent RV32I instruction-set simulator ([`tb/verilator/iss.h`](tb/verilator/iss.h))
runs in step with the RTL and compares **every retired instruction** — PC,
register writeback, and every memory store — aborting at the *exact*
instruction on any divergence. Five stimulus layers all feed
this check, on **both cores**:

| Layer | Command | Coverage |
|---|---|---|
| Directed tests | `make regress` | Targeted corner cases + every past bug as a regression |
| Official ISA suite | `make regress-isa` | riscv-tests rv32ui **40/40** |
| Constrained-random | `make regress-rand` | 25 seeds × 3000 instructions, seeded/reproducible |
| Violation stress | `make regress-rand-vio` | 1,185 real load-ordering violations exercising the recovery path |
| Benchmark | `make coremark` | 433M-instruction run, CRC-validated **and** lockstep-checked |

Every real bug is root-caused and written up in
[`docs/BUGLOG.md`](docs/BUGLOG.md) (**14 so far**) — including ones only
this infrastructure could catch: an issue-queue flush that cleared *zero*
entries because a 6-bit relative age can never exceed 63 (B013), an
operand-decay bug during a pipeline hold that compiled C can never trigger
(B011, caught by adversarial design review), and a one-cycle predictor
race caught by its own assertion on its first run (B014). Every
architectural decision, with the alternatives considered, is logged in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

---

## 📂 Repository layout

```
rtl/
  core/   5-stage in-order pipeline + shared leaf units (ALU, regfile, CSRs)
  ooo/    2-wide out-of-order core (rename, ROB, IQ, SQ/LQ, store sets, gshare/BTB/RAS)
  npu/    4×4 int8 systolic array + MMIO front end
  mem/    banked M9K instruction ROM, byte-enabled block-RAM dmem (MIF-initialized)
  soc/    mmio (LEDs / switches / 7-segment displays)
  top/    de10_top (DE10-Lite board wrapper: PLL, reset sync)
tb/verilator/   C++ harness + golden-model ISS (lockstep co-sim)
sw/       assembly + C tests, C runtime, CoreMark port, MNIST MLP (sim + board)
synth/    Quartus project for the DE10-Lite (+ checked-in memory images)
docs/     BASELINE, OOO, LQ, STORESET, NPU, VERIFICATION, DECISIONS, BUGLOG, DEMO
scripts/  MNIST training/quantization, random test generator, hex→MIF flow
```

---

## ▶️ Reproduce the numbers

```bash
make verify          # in-order core: directed + ISA + random suites, all lockstep-checked
make verify-ooo      # same + violation stress on the out-of-order core
make coremark        # in-order CoreMark (CRC-validated)   → 1.177 CoreMark/MHz
make coremark-ooo    # out-of-order CoreMark               → 1.397 CoreMark/MHz (+18.8%)
make npu-mlp         # MNIST MLP: software vs NPU, bit-exact + measured speedup
make npu-mlp-board   # the board demo's self-test, run in simulation (both cores: -ooo)
make npu-tb          # NPU unit testbench vs C++ golden model
make mif             # rebuild the FPGA memory-init images from the demo binaries
```

Toolchain: Verilator 5.048, xPack riscv-none-elf-gcc 15.2.0, Quartus Prime
Lite 20.1. Target board: Terasic **DE10-Lite** (Intel MAX 10
10M50DAF484C7G). Board bring-up + demo guide: [`docs/DEMO.md`](docs/DEMO.md).

---

## 🗺️ Roadmap

- ✅ RV32I baseline → CoreMark → tagged `v1.0-inorder-baseline`
- ✅ 2-wide out-of-order core → `v2.0-ooo`
- ✅ Tightly-coupled int8 NPU + quantized MNIST → `v3.0-npu`
- ✅ Industrial-grade verification (lockstep, constrained-random, ISA suite, violation stress)
- ✅ FPGA bring-up: PLL + SDC timing closure, block-RAM memories → `v3.1-inorder-fpga`
- ✅ Speculative loads + load queue + store-set memory-dependence predictor
- ✅ OoO core on the board: issue-queue select restructured (8.42 → 19.65 MHz), M9K program ROM, standalone flash boot
- 🚧 On-board MNIST demo: RTL + software done, sim-verified on both cores (8/8 images); **bitstream now builds** (gshare→M9K shrink D024 freed the fabric: fits at 88% LEs, timing MET +16.8 ns, `.sof` built) — on-silicon flash is the last step
- 🔜 2-stage pipelined scheduler (the ~42 MHz needed for the OoO core to beat in-order in wall-clock)
- 🔭 ASIC tapeout of the NPU via Tiny Tapeout (SkyWater 130 nm)

---

## 👩‍💻 Author

**Hanna Ashkar** — Electrical Engineering, Technion
FPGA · Digital Design · Computer Architecture · RISC-V
