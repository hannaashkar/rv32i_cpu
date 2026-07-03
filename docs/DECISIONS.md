# Architectural & Project Decisions

One paragraph per decision: what was decided, the options considered, and why.
Decisions are Hanna's; entries are logged so each one can be defended later.

---

## D012 — 2026-07-03 — Full Zicsr scaffold + pipeline valid bit for instret

Two coupled choices for the measurement CSRs (rdcycle/rdinstret). (1) CSR
scope: Hanna chose a **full Zicsr scaffold** — a `csr_file` module with
generic address decode and all six instruction forms (CSRRW/S/C, register
and immediate) — over a counters-only read path. Costs more decode and
test surface now, but mstatus/mtvec/mepc slot into the same case statement
when traps arrive, with no datapath rework. mscratch is implemented as the
first writable CSR so the write path is tested logic rather than dead
scaffolding; counter CSRs are read-only (writes dropped until traps can be
raised). (2) Retirement counting: Hanna chose a **1-bit valid flag**
flowing IF→WB through the pipeline registers (flushes/bubbles clear it;
instret increments when a valid instruction reaches WB) over a
count-non-NOPs heuristic, which would miscount real NOPs in compiled code
— noise in the exact number (IPC) this stage exists to produce. The valid
bit is also groundwork the OoO core needs regardless. Placement: CSR ops
execute in EX (read + write commit there) — safe because nothing that
reaches EX can be killed in this pipeline (no traps; mispredicts flush
only IF/ID + ID/EX), and the read value returns through the existing EX
result mux so forwarding needs no changes.

## D011 — 2026-07-03 — B007 fix: latch forwarded store data only (F1)

EX/MEM will capture `rs2_fwd_base` (the forwarded rs2) instead of raw
`rs2_dataE`. The considered alternative — an extra WB→MEM store-data bypass
that removes the `lw x5; sw x5` load-use stall — was declined for the
baseline to keep MEM simple; can be revisited as an IPC optimization with
its own measurement.

## D010 — 2026-07-03 — Keep combinational memories for the baseline (Eb)

Byte/half load-store support is added on top of the existing combinational
imem/dmem. The synchronous-read/BRAM rework (fixes BUGLOG B006, changes
fetch/load latency and the hazard window) is deliberately deferred to its
own post-baseline stage, so the "before" measurements reflect today's
microarchitecture and memory is only redesigned once, together with the
PLL/timing work.

## D009 — 2026-07-03 — LUI/AUIPC through the ALU (D1)

U-type immediates go through the normal ALU path: LUI = pass-operand-B,
AUIPC = ADD with a new pc-vs-rs1 mux on operand A. Avoids widening the WB
mux; the operand-A pc mux is shared with jump/branch target logic.

## D008 — 2026-07-03 — Jumps resolve in EX via the redirect path (C1)

JAL target = pc+imm (existing branch-target adder), JALR target = ALU
rs1+imm; rd receives pc+4. Jumps reuse the mispredict/redirect machinery
and are added to the BTB, so repeat encounters are free; a first-seen jump
costs the normal 2-cycle redirect. The early-JAL-in-ID alternative (1-cycle
first-visit saving, extra PC mux + ID adder + hazard cases) was declined —
the BTB erases most of its benefit.

## D007 — 2026-07-03 — Dedicated branch comparator in EX (B2)

Branch conditions (BEQ/BNE/BLT/BGE/BLTU/BGEU) come from a small dedicated
comparator on the forwarded operands, not from ALU flags. ~70 extra LEs
buys a shorter branch-resolve path (the EX redirect path is the current
critical path) and the ALU/branch-unit split the future OoO core needs.

## D006 — 2026-07-03 — ALU decode flattened to funct3-based scheme (A2)

Replace the two-level ALUOp/alu_control decode with direct funct3-indexed
operation select, instr[30] disambiguating ADD/SUB and SRL/SRA, and the
opcode class gating whether funct7 participates at all. This makes bug
B004 (immediate bits spoofing funct7 on I-type) structurally impossible,
costs the same LEs as patching the old scheme (the barrel shifter
dominates either way: shared reversed shifter, ~200 LEs), and produces the
uop shape the OoO decoder will reuse. Full micro-op decode in ID (A3) was
rejected as premature for the 1-wide baseline.

## D005 — 2026-07-03 — Remove debug_x3 instead of restoring it

The repo shipped with a dangling `debug_x3` connection (see BUGLOG B001).
Options: (a) delete the debug wire from `cpu_pipeline.v`, or (b) restore the
`debug_x3` output port in `register_file.v`. Chose **(a)**: LEDs are driven
through MMIO now, the wire's only consumer was a commented-out debug assign,
and the Verilator testbench will expose full register state anyway — a
hardwired x3 tap is obsolete scaffolding.

## D004 — 2026-07-03 — Repo layout: rtl/{core,mem,soc,top} + tb/sw/synth/docs

Options: flat `src/` (matches the old README) vs. subsystem folders. Chose
subsystem folders because the roadmap (OoO core, NPU, MMIO peripherals) adds
tens of modules; separating "the CPU" (`rtl/core`) from "memories"
(`rtl/mem`) and "the SoC around it" (`rtl/soc`, `rtl/top`) keeps interfaces
honest and makes the eventual `ooo/` and `npu/` additions non-disruptive.
Testbenches live outside `rtl/` so the synthesis file list is exactly
"everything in rtl/".

## D003 — 2026-07-03 — RV32I completion is a stage before CoreMark

The core currently implements ADD/SUB/AND/OR/XOR/SLT, ADDI, LW, SW, BEQ.
Without JAL/JALR (calls), LUI/AUIPC (constants/addressing), shifts, and
byte/half memory ops, no compiled C runs at all. Decision: insert an explicit
"complete RV32I + fix decode bugs" stage between Verilator bring-up and the
CoreMark baseline, done in small increments, each with its own tests, with
microarchitectural choices approved by Hanna.

## D002 — 2026-07-03 — Project home = github.com/hannaashkar/rv32i_cpu

The GitHub repo (uploaded 2025-12-10) is the canonical source going forward;
the local trees `C:\Hanna_Projects\HANNA_CPU` and `Desktop\CleanCPU` remain
untouched as read-only backups. The repo versions were verified
file-by-file against the last known-good local Quartus build: functionally
identical except two fixes (I-type ALUOp, id_ex_reg flush) and one breakage
(B001, fixed in the restructure).

## D001 — 2026-07-03 — Native Windows toolchain instead of WSL

The original plan assumed WSL2, but this machine has no WSL distro
installed. Options: (a) install WSL2 (admin + reboot; Spike easy), (b) native
Windows tools. Hanna chose **(b)**: MSYS2 (make + g++ + Verilator) and xPack
riscv-none-elf-gcc, all user-level installs under `C:\Users\ASUS\tools\`.
Consequence: Spike lockstep co-simulation is deferred (painful to build on
Windows); the golden-model strategy will be revisited when verification
ramps up. Quartus Prime Lite 20.1.1 already lives at `C:\intelfpga_lite\20.1`
on this same machine, so no git-bridge is needed — Quartus opens
`synth/rv32i_cpu.qpf` directly.
