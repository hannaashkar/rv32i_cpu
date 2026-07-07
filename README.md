<p align="center">
  <img src="https://img.shields.io/badge/RISC--V-RV32I_+_Zicsr-brightgreen?style=for-the-badge&logo=riscv" />
  <img src="https://img.shields.io/badge/Core-2--wide_Out--of--Order-orange?style=for-the-badge" />
  <img src="https://img.shields.io/badge/NPU-4×4_int8_Systolic-red?style=for-the-badge" />
  <img src="https://img.shields.io/badge/FPGA-DE10--Lite_(MAX_10)-blue?style=for-the-badge&logo=intel" />
</p>

# RISC-V SoC — from a 5-stage core to an out-of-order CPU with an AI accelerator

**Hanna Ashkar** · Electrical Engineering, Technion · Digital Design / Computer Architecture / RISC-V

A RISC-V **RV32I + Zicsr** system-on-chip built and measured in stages: a
classic 5-stage in-order pipeline, upgraded into a **2-wide out-of-order
superscalar** with register renaming and speculation, then extended with a
tightly-coupled **4×4 int8 systolic-array NPU** that runs a real quantized
MNIST neural network. Every stage is **benchmarked, golden-model-verified,
and reproducible** — measurement matters as much as the RTL.

https://github.com/user-attachments/assets/236d160b-ccb6-4e1c-92c8-c92e5c0e4397

---

## 📊 Results at a glance

| Stage | What it is | Headline number |
|---|---|---|
| **In-order baseline** (`v1.0`) | Classic 5-stage, forwarding, branch prediction | **1.177 CoreMark/MHz**, IPC 0.849 |
| **Out-of-order core** (`v2.0`) | 2-wide, renaming, ROB, speculation + recovery | **1.397 CoreMark/MHz (+18.8%)**, IPC 1.008 |
| **NPU + MNIST MLP** (`v3.0`) | 4×4 int8 systolic array, quantized 784→32→10 net | **86× inference speedup**, 97.1% accuracy |
| **Verification** | Golden-model lockstep co-sim + random + ISA suite | **11 bugs** found & documented, 0 divergence |

All numbers are from **cycle-accurate simulation** using the core's own
hardware performance counters, CRC-validated where applicable, and
reproducible with the commands below. Full methodology in
[`docs/BASELINE.md`](docs/BASELINE.md).

---

## 🧩 What's inside

### 1. In-order core — the baseline (`rtl/core/`)
Classic 5-stage pipeline (IF → ID → EX → MEM → WB) with full forwarding
(EX←MEM, EX←WB, store-data, register write→read bypass), load-use
interlock, a 64-entry 2-bit BHT + tagged BTB, and byte/half/word memory.
Complete RV32I user-level ISA plus Zicsr counters (cycle/instret) for
self-measurement. Runs compiled C and the full CoreMark benchmark.

### 2. Out-of-order core — the upgrade (`rtl/ooo/`, [`docs/OOO.md`](docs/OOO.md))
A 2-wide out-of-order superscalar that runs the **identical binary** as the
baseline, +18.8% faster:
- **Register renaming** — R10K-style merged physical register file (64
  registers), RAT + free list
- **32-entry ROB**, 2-wide dispatch/retire; **16-entry unified issue queue**
- **Speculative execution with full recovery** — gshare (1024) + BTB (64) +
  RAS (8), 8 per-branch RAT checkpoints, single-cycle mispredict restore
- **Load/store queue** (8 entries) with store-to-load forwarding and
  conservative memory disambiguation

### 3. NPU — the accelerator (`rtl/npu/`, [`docs/NPU.md`](docs/NPU.md))
A 4×4 **output-stationary systolic array** of int8 MAC units, memory-mapped
so both cores can drive it, mapping to **16 hardware multipliers** on the
FPGA. It runs a **quantized MNIST MLP** (784→32→10, symmetric int8,
TFLite-style requantization) at **97.1% accuracy** — and the same network
runs **86× faster** on the array than in software on the CPU. Correctness is
proven **bit-exact** against the software path, and the memory-ordering
between CPU and accelerator is enforced in hardware (no software polling).

---

## 🧪 Verification — the part that makes it real

The whole SoC is checked by **golden-model lockstep co-simulation**: an
independent RV32I instruction-set simulator ([`tb/verilator/iss.h`](tb/verilator/iss.h))
runs in step with the RTL and compares **every retired instruction** — PC,
register writeback, and every memory store — aborting at the *exact*
instruction on any divergence. Three independent stimulus layers all feed
this check:

| Layer | Command | Coverage |
|---|---|---|
| Directed tests | `make regress` | Targeted corner cases + bug regressions |
| Official ISA suite | `make regress-isa` | riscv-tests rv32ui **40/40** |
| Constrained-random | `make regress-rand` | 25 seeds × 3000 instructions, seeded/reproducible |
| Benchmark | `make coremark` | 433M-instruction run, CRC-validated |

Every real bug is root-caused and written up in
[`docs/BUGLOG.md`](docs/BUGLOG.md) (11 so far) — including subtle ones this
infrastructure caught that directed tests missed, like a speculative
store-forwarding hazard and an out-of-order operand-decay bug. Every
architectural decision, with the alternatives considered, is logged in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

---

## 📂 Repository layout

```
rtl/
  core/   5-stage in-order pipeline + shared leaf units (ALU, regfile, CSRs)
  ooo/    2-wide out-of-order core (rename, ROB, IQ, LSQ, gshare/BTB/RAS)
  npu/    4×4 int8 systolic array + MMIO front end
  mem/    imem, dmem
  soc/    mmio (LEDs / switches)
  top/    de10_top (DE10-Lite board wrapper)
tb/verilator/   C++ harness + golden-model ISS (lockstep co-sim)
sw/       assembly + C tests, C runtime, CoreMark port, MNIST MLP
synth/    Quartus project for the DE10-Lite
docs/     BASELINE, OOO, NPU, VERIFICATION, DECISIONS, BUGLOG
scripts/  MNIST training/quantization, random test generator
```

---

## ▶️ Reproduce the numbers

```bash
make verify        # in-order core: directed + ISA + random suites, all lockstep-checked
make verify-ooo    # same suites on the out-of-order core
make coremark      # in-order CoreMark (CRC-validated)   → 1.177 CoreMark/MHz
make coremark-ooo  # out-of-order CoreMark               → 1.397 CoreMark/MHz (+18.8%)
make npu-mlp       # MNIST MLP: software vs NPU, bit-exact + measured speedup
make npu-tb        # NPU unit testbench vs C++ golden model
```

Toolchain: Verilator 5.048, xPack riscv-none-elf-gcc 15.2.0, Quartus Prime
Lite 20.1. Target board: Terasic **DE10-Lite** (Intel MAX 10
10M50DAF484C7G, 50 MHz).

---

## 🗺️ Roadmap

- ✅ RV32I baseline → CoreMark → tagged `v1.0-inorder-baseline`
- ✅ 2-wide out-of-order core → `v2.0-ooo`
- ✅ Tightly-coupled int8 NPU + quantized MNIST → `v3.0-npu`
- ✅ Industrial-grade verification (lockstep, constrained-random, ISA suite)
- 🔜 On-board FPGA demo (BRAM memories + timing closure) — live MNIST on the DE10-Lite
- 🔜 Speculative loads + load queue (further IPC)
- 🔭 ASIC tapeout of the NPU via Tiny Tapeout (SkyWater 130 nm)

---

## 👩‍💻 Author

**Hanna Ashkar** — Electrical Engineering, Technion
FPGA · Digital Design · Computer Architecture · RISC-V
