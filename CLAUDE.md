# rv32i_cpu — Project Guide for Claude

Hanna Ashkar's RISC-V SoC portfolio project (EE, Technion). An existing
5-stage in-order RV32 pipeline is being upgraded, in stages, into a complete
SoC. Final deliverables include benchmark numbers (IPC before/after, NPU
speedup, coverage %) — **measurement and reproducibility matter as much as
the RTL**.

## Roadmap

1. **Baseline** (current): Verilator bring-up → complete RV32I → CoreMark →
   measure baseline IPC → tag `v1.0-inorder-baseline`.
2. **2-wide out-of-order core**: register renaming, ~32-entry ROB, ~16-entry
   issue queue, 48–64 physical registers, gshare + BTB + RAS, speculative
   execution with full recovery, load/store queue.
3. **Tightly-coupled NPU**: 4×4 int8 systolic array (matmul) via MMIO or
   custom instructions, running a real quantized MNIST-class net on the FPGA.
4. **Industrial-grade verification**: Verilator testbenches, SVA assertions,
   constrained-random tests, lockstep co-sim vs a golden model, functional
   coverage, documented bug log.
5. Eventually: PPA analysis and a Tiny Tapeout submission (separate repo).

## Division of labor (most important rule)

- **Claude owns infrastructure**: Makefiles, Verilator testbench plumbing,
  scripts, CI, software builds (CoreMark, NN code), plotting, docs
  scaffolding, debugging assistance.
- **Hanna owns microarchitecture**: rename scheme, structure sizing,
  recovery mechanism, LSQ design, NPU dataflow. For any architectural
  decision, present 2–3 options with tradeoffs (complexity, LEs, timing,
  IPC impact) and **wait for her decision**. Never silently implement a
  major design choice.
- Hanna must be able to defend every line in a job interview: when writing
  or changing RTL, explain WHAT and WHY at a level she can re-explain.

## Process rules

- Small verified increments; one component at a time, with its own unit
  test, merged only when green. Never generate large blobs of untested RTL.
- `main` always passes the full test suite. Feature branches for everything
  (`ooo-rename`, `ooo-rob`, `npu-array`, ...). Conventional, descriptive
  commits. Tag milestones.
- Every RTL module gets: header comment (purpose, interfaces, assumptions),
  SystemVerilog assertions for invariants, a unit testbench where practical.
- Log every real bug in `docs/BUGLOG.md` (symptom, root cause, how caught,
  fix). Log every architectural decision in `docs/DECISIONS.md`.
- Update the **Current status** section below at the end of every session.

## Environment (reality — differs from the original kickoff!)

- **Everything runs natively on Windows 11.** There is NO WSL on this
  machine (decision D001). Shell: PowerShell / Git Bash.
- Simulation toolchain (user-level, no admin): MSYS2 under
  `C:\Users\ASUS\tools\msys64` (make, g++, Verilator) and xPack
  riscv-none-elf-gcc under `C:\Users\ASUS\tools\`. Installers staged in
  `C:\Users\ASUS\tools\downloads`.
- Spike co-simulation is deferred (hard to build on Windows); golden-model
  strategy to be revisited when verification ramps up.
- **Quartus Prime Lite 20.1.1** at `C:\intelfpga_lite\20.1` — same machine,
  opens `synth/rv32i_cpu.qpf` directly. CLI:
  `C:\intelfpga_lite\20.1\quartus\bin64\quartus_map.exe rv32i_cpu` (run in
  `synth/`) for a fast compile check.
- Target board: Terasic DE10-Lite (MAX 10 10M50DAF484C7G, 50 MHz clock).
- **Pin assignments in `synth/rv32i_cpu.qsf` are sacred** — copied verbatim
  from the proven 2025-12-01 build; never modify without telling Hanna.
- Historical source trees `C:\Hanna_Projects\HANNA_CPU` and
  `C:\Users\ASUS\Desktop\CleanCPU` are read-only backups — do not touch.
- Keep everything Quartus-20.1-compatible (plain Verilog-2001 currently);
  flag any SystemVerilog construct that Quartus Lite might reject.

## Repo layout

- `rtl/core/` — pipeline (`cpu_pipeline.v` is the CPU top), pipeline regs,
  control/ALU/regfile/decode, hazard + forwarding units, branch predictor
- `rtl/mem/` — `imem.v` (currently a hardcoded demo ROM), `dmem.v` (256
  words)
- `rtl/soc/` — `mmio.v` (LEDs @ `0x4000_0000`, switches @ `0x4000_0004`;
  IO region = `addr[31:28] == 4`)
- `rtl/top/` — `de10_top.v` (reset sync + ripple clock divider ≈ 0.75 Hz)
- `tb/legacy/` — original ModelSim TB; `tb/verilator/` — C++ harness (WIP)
- `sw/`, `synth/`, `docs/`, `scripts/`

## Design state (updated 2026-07-03, post RV32I completion)

- Classic 5-stage: IF → ID → EX → MEM → WB. Forwarding EX←MEM and EX←WB
  incl. store data (B007); regfile write→read bypass (B008); load-use
  stall; 64-entry 2-bit BHT + tagged BTB queried in IF, trained in EX by
  branches AND jumps; mispredict/redirect costs 2 cycles.
- Decode: flat funct3-based ALU decode (D006/A2, `alu_ops.vh` classes);
  dedicated branch comparator (D007/B2); jumps resolve in EX via the
  redirect path with pc+4 linked through the EX result mux (D008/C1);
  LUI/AUIPC through the ALU with a pc operand-A mux (D009/D1); dmem does
  byte/half lanes + sign/zero extension via funct3 in MEM (D010/Eb).
- **ISA: full RV32I user-level compute — all ALU ops + shifts, SLTU/SLTIU,
  all six branches, JAL/JALR, LUI/AUIPC, LB/LBU/LH/LHU/LW, SB/SH/SW.**
  Compiled C can run. Still missing: FENCE (safe to treat as NOP),
  ECALL/EBREAK/traps, CSRs (next: cycle/instret for measurement), M ext.
- Tests: `make regress` = 7 directed suites in `sw/tests/` (ALU incl. B004
  regression, branches, jumps incl. BTB-stale return, LUI/AUIPC, sub-word
  memory lanes/sign, store-forwarding, smoke). All green.
- Memory: combinational imem/dmem (B006 BRAM rework deferred, D010);
  `SIM_BIG_MEM` (set by the Verilator build) gives 256 KB memories in sim
  while synthesis keeps 4 KB imem / 1 KB dmem.
- Remaining known issues: B005 (ripple clock / timing), B006 (FF
  memories) — both deliberately post-baseline; see BUGLOG watch list for
  minor quirks (spurious hazard stalls from immediate bits, word-only MMIO).

## Current status (update every session!)

**2026-07-03** — Task 1 steps 1–5 done:
- Explored and documented the legacy code; canonical source = GitHub repo
  `hannaashkar/rv32i_cpu`, verified file-by-file against the last local
  Quartus build.
- Restructured into `rtl/tb/sw/synth/docs` (branch `restructure`, pushed);
  fixed B001; clean Quartus project; BUGLOG/DECISIONS seeded. Local `main`
  has everything merged; **push of `main` pending Hanna** (permission-gated).
- Toolchain installed & working: MSYS2 UCRT64 (Verilator 5.048, make, g++)
  + xPack riscv-none-elf-gcc 15.2.0. Gotchas encoded in the Makefile:
  gcc 16.1.0-5 cannot link `-Os` C++ (force `-O2`), Verilator's `__ALL.cpp`
  rule breaks under MSYS make (use `VM_PARALLEL_BUILDS=1`), and
  `sc_time_stamp()` must be defined explicitly (MinGW has no weak symbols).
- Verilator harness live (branch `sim-harness`): `make test` assembles
  `sw/tests/*.S` (riscv-gcc → objcopy → scripts/bin2hex.py → hex), runs
  `obj_dir/Vcpu_pipeline +imem=<hex>`; test-end protocol = store to
  0x40000008 (1 = PASS); `make wave` dumps sim.fst. imem reworked for
  $readmemh loading (+imem runtime override); pipeline signals exposed to
  the TB via `/*verilator public_flat_rd*/` comments (Quartus-invisible).
  **First program PASSes in 42 cycles**; `quartus_map` still 0 errors.
- New bug found while writing the smoke test: B007 — store data bypasses
  forwarding (EX/MEM latches unforwarded `rs2_dataE`).

**2026-07-03 (later)** — RV32I completion executed per decisions D006–D011
(branches F → A → B → D → C → E, each tested + Quartus-checked + merged):
- Fixed B007 (store-data forwarding) and discovered+fixed B008 (regfile
  write→read bypass) — both caught by `sw/tests/store_fwd.S`.
- A2 flat decode + shifts + SLTU (killed B004; LED demo works — B002);
  B2 branch unit (all six conditions); D1 LUI/AUIPC; C1 JAL/JALR through
  the redirect path; Eb sub-word dmem with funct3 in MEM.
- `make regress`: 7/7 suites green; quartus_map 0 errors throughout.

**Next**: cycle/instret CSRs (rdcycle/rdinstret for measurement) →
C runtime bring-up (crt0, linker layout for Harvard imem/dmem, +dmem
data-image loading) → CoreMark port → baseline IPC → docs/BASELINE.md →
tag v1.0-inorder-baseline. Consider porting riscv-tests rv32ui as the
acceptance gate alongside.
