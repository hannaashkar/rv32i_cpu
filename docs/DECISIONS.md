# Architectural & Project Decisions

One paragraph per decision: what was decided, the options considered, and why.
Decisions are Hanna's; entries are logged so each one can be defended later.

---

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
