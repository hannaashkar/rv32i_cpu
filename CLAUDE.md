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

## Design state (verified 2026-07-03)

- Classic Harris & Harris 5-stage: IF → ID → EX → MEM → WB. Forwarding
  EX←MEM and EX←WB; load-use stall; 64-entry 2-bit BHT + tagged BTB queried
  in IF, updated in EX; mispredict costs 2 cycles (flush IF/ID + ID/EX).
- **ISA actually working: ADD SUB AND OR XOR SLT, ADDI (see B004), ANDI ORI
  XORI SLTI, LW, SW, BEQ.** Missing: JAL, JALR, LUI, AUIPC, all shifts,
  SLTU/SLTIU, byte/half loads/stores, BNE..BGEU, FENCE, CSRs, traps, M.
  → **No compiled C can run until RV32I is completed** (decision D003).
- Known bugs and quirks: see `docs/BUGLOG.md` (B004 ADDI/SUB decode spoof,
  B002 no shifter, B005 ripple clock fails timing, B006 memories synthesize
  to FFs — 0 BRAM bits, 12.5k FFs, 15.4k LEs at last fit).
- Synthesis check: `quartus_map` passes with 0 errors on the restructured
  tree (2026-07-03).

## Current status (update every session!)

**2026-07-03** — Task 1 steps 1–3 done:
- Explored and documented the legacy code; canonical source = GitHub repo
  `hannaashkar/rv32i_cpu`, verified file-by-file against the last local
  Quartus build.
- Restructured into `rtl/tb/sw/synth/docs` (branch `restructure`, pushed);
  fixed B001 (dangling `debug_x3` — repo didn't compile); created clean
  Quartus project; seeded BUGLOG/DECISIONS; verified with `quartus_map`
  (0 errors). Local `main` has the merge; **push of `main` pending Hanna**
  (permission-gated).
- Toolchain installers downloaded to `C:\Users\ASUS\tools\downloads`
  (MSYS2 base + xPack riscv-none-elf-gcc 15.2.0), not yet installed.

**Next**: install toolchain → Verilator harness (Makefile, `$readmemh`
program loading, pass/fail via magic MMIO address, waveform dump on demand)
→ first program in simulation → RV32I completion plan (options for Hanna).
