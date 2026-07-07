# Architectural & Project Decisions

One paragraph per decision: what was decided, the options considered, and why.
Decisions are Hanna's; entries are logged so each one can be defended later.

---

## D018 — 2026-07-07 — OoO core FPGA board port; clocked at 7.14 MHz (issue-queue Fmax cap)

**Context:** After the in-order core reached the board (D016/D017), the goal
was to run the 2-wide OoO core (ooo_cpu) on the DE10-Lite too. Hanna chose
"BRAM port first, LQ later" and green-lit the implementation.

**What was done (branch ooo-bram-port, NOT merged — main stays in-order):**
- dmem `SYNC_READ=1` on ooo_cpu with an IPC-neutral load fold, same principle
  as the in-order core: the load result lands in the SAME writeback cycle it
  did before, so load-to-use (2 cyc), wakeup and the mispredict path are
  unchanged. The RAM select is deferred to WB —
  `wb_result2 = wb2_use_dmem ? dmem_rdata : wb_val[2]` — feeding the three
  consumers (PRF write, EX bypass, ROB value). SQ-forward/MMIO/NPU are
  captured into wb_val[2] at EX→WB; a plain RAM load takes the registered
  dmem read in WB. No combinational loop (the registered read breaks
  addr→data). imem left combinational: it is not on the critical path, and
  would not infer M9K anyway (same MAX 10 initialized-ROM limit as in-order).
- de10_top switched from cpu_pipeline to ooo_cpu (drop-in, same interface).

**The finding:** STA gives **OoO Fmax = 8.42 MHz**. The critical path is
ENTIRELY inside the issue queue (`ooo_iq:IQ0` u[0] → r2, ~118 ns): the
un-pipelined select + wakeup + tag-broadcast across 16 entries — the classic
OoO Fmax limiter — on MAX 10's budget fabric. imem/dmem are not on it.

**Decision:** clock the OoO core at 7.14 MHz (PLL `clk0_divide_by=7`) with
margin instead of pipelining the scheduler now. Timing MET (+9.35 ns), dmem
block RAM (103 segments), 0 errors; the OoO walker runs on the board
(~1.7 s/step). Options weighed: (a) run slow now [chosen — cheap, proves
OoO-on-silicon], (b) pipeline the IQ select-wakeup [big stage, raises Fmax,
changes IPC — deferred], (c) keep OoO sim-only.

**Lesson (worth stating in an interview):** wall-clock perf = IPC × Fmax. The
OoO core wins per-MHz (+18.8% IPC) but its 7× lower Fmax makes it ~6× slower
on THIS board. Realizing the IPC win on hardware requires pipelining the
issue queue — the recommended next OoO stage.

## D017 — 2026-07-07 — PLL clock + real .sdc for honest timing closure (B005)

**Context:** The CPU had been clocked by bit 25 of a free-running counter (a
"ripple" clock, ~0.75 Hz) with no timing constraints — setup slack −13.05 ns,
no meaningful Fmax. B005.

**Decision (Hanna chose "PLL + SDC, self-paced demo"; options offered:
SDC-only on CLOCK_50, or measure-first):**
- A MAX 10 ALTPLL turns the 50 MHz board oscillator into a clean CPU clock
  (`pll.v`, 1:1) with a `locked` signal; the core is held in reset until the
  PLL locks, then the KEY[0] button is double-flopped into the CPU domain.
  The ripple divider is gone.
- The project's first real `.sdc`: `create_clock` on CLOCK_50 +
  `derive_pll_clocks` + `derive_clock_uncertainty`; false-paths on the async
  KEY/SW/LEDR pins. The PLL is instantiated directly (not a generated IP
  blob) so the clocking is self-contained and version-controlled.
- Because the CPU no longer runs at a human-visible rate, the LED demo paces
  itself in software (a delay-loop walker, `sw/demo/led_demo.S`).

**Result (Quartus 20.1, 10M50DAF484C7G, in-order top):** Fitter 0 errors;
STA slow-85C **Fmax = 53.95 MHz** — meets 50 MHz with +1.466 ns setup slack,
0 unconstrained clocks/ports. The synchronous BRAM memories (D016) removed
the async fetch/load critical paths that made this closable. Frequency was
confirmed by STA as agreed; 50 MHz stands with ~8% headroom.

## D016 — 2026-07-07 — Synchronous-read memories for M9K, folded into the pipeline (B006)

**Context:** The in-order core's imem/dmem used combinational (async) reads,
which cannot map to MAX 10 M9K block RAM (they need a registered read). This
cost ~12.5k logic registers and left 0 block-RAM bits (B006), and the long
async memory paths are a big part of the timing failure (B005).

**Decisions taken (Hanna: "pivot to B005/B006", in-order first, minimal /
stall-based latency):**
1. *Bring-up vehicle* — do the memory rework on the in-order core first
   (small, isolates bugs), then port to OoO. dmem/imem gained a `SYNC_READ`
   parameter: the in-order core sets it, the OoO core keeps combinational
   reads (unchanged) until its own memory stage.
2. *Latency handling* — the "extra" BRAM cycle is absorbed by **folding**,
   not stalling. Synchronous BRAM adds one read-latency cycle, but the
   pipeline already had a register at each memory output (the IF/ID
   instruction latch and the MEM/WB mem-data latch). Those latches are
   folded *into* the memories' own read registers, so the load-use timing,
   forwarding and 2-cycle mispredict penalty are all unchanged — **IPC is
   identical**. (Options considered: add a load-use stall cycle — simpler
   RTL, small IPC loss; or a full MEM1/MEM2 memory pipeline — more RTL. The
   fold gives the best of both here because the registers already existed.)
3. *Fetch squash* — with imem's registered output serving as the Decode
   instruction, wrong-path/startup slots are squashed to a NOP via the
   existing pipeline `valid` bit instead of inside IF/ID; imem gets a `hold`
   enable mirroring the IF/ID stall (B012).

**Result:** dmem infers block RAM; imem stays logic on MAX 10 (initialized-
ROM MIF limitation) but is structurally M9K-ready and no longer on the async
critical path — full block-RAM imem via `ram_init_file` is deferred to the
on-board large-program stage. Both cores pass full lockstep verification.

## D015 — 2026-07-03 — MNIST MLP quantization scheme (executed under the
## "all done" directive; decided by Claude, documented for review)

784→32(ReLU)→10 MLP, trained offline in numpy (`scripts/train_mlp.py`,
seeded, 97.10% float). Quantization: **symmetric per-tensor int8** with
TFLite-style fixed-point requantization — `h = clamp((acc*M1 + rnd) >>
N1, 0, 127)` in int64 — over (a) asymmetric/per-channel quantization
(better accuracy headroom, but zero-point cross terms and per-channel
scales complicate both the C driver and the defense story for zero gain
at this accuracy: integer pipeline hits 97.13%, above float) and (b)
power-of-two scales only (simplest requant — a bare shift — but cost
~1% accuracy in trials elsewhere; the int64 multiply happens 32× per
batch, negligible next to 100K MACs). The hidden scale is calibrated
(`sh = max_activation/127` over 1000 training samples) because the naive
`sh = 1/127` saturates (int accuracy collapses to 60%) — the script
auto-selects and records the choice. Layer 2 keeps raw int32 logits +
argmax (classification needs no requant). Batch = 4 images through the
4 array columns for full utilization. Bit-exactness chain: numpy integer
reference → exported goldens → on-core soft int8 path → NPU path, each
step compared exactly.

## D014 — 2026-07-03 — NPU: MMIO-mapped 4×4 output-stationary systolic
## array with hardware ordering interlocks (executed under the "all done"
## directive; decided by Claude, documented for review)

Full spec in docs/NPU.md. Four choices and their alternatives:

1. **Interface: MMIO region 0x5xxx_xxxx** over custom instructions.
   Zero decoder changes, works identically on both cores, plain-C
   driver, and the OoO core's SQ already makes MMIO side effects
   non-speculative. Custom matmul instructions would save ~9 stores per
   tile but touch decode/rename/IQ on the OoO core — revisit only if
   the measured MMIO overhead justifies it.
2. **Dataflow: output-stationary** over weight-stationary (TPU-style)
   and over a flat combinational MAC array. OS keeps the 16 partial
   sums in the PEs across GO commands, so K-tiling (the common loop:
   784 deep in layer 1) needs no C read-modify-write traffic — just
   stream new A/B tiles and GO. Weight-stationary only wins when one
   weight tile is reused across many activation tiles, which a batch-4
   MLP never does (weights change every k-step). A combinational MAC
   array is not a systolic array — fails the roadmap deliverable and
   teaches nothing about dataflow timing.
3. **Tile buffers: 4×4 registers with accumulate-across-GO** (16 B A +
   16 B B) over K-deep staging SRAM (e.g. K=256: 2 KB). Deep staging
   amortizes CTRL traffic but costs ~16K FFs while B006 (no BRAM
   inference yet) is still open — the register-tile design is honest
   about today's FF-memory reality and keeps the unit fully testable.
4. **Ordering: hardware interlocks, software never polls.** OoO: IO
   loads replay until every older store has drained AND the array is
   idle (`busy_next`); the SQ head backpressures (`mw_ready`) instead
   of draining into a busy NPU. In-order: NPU accesses stall in EX on
   `busy_next`. Alternative — software delay loops / poll protocols —
   rejected: unverifiable timing contracts, and the interlock is what
   makes the instantaneous ISS mirror lockstep-exact (busy is
   architecturally unobservable). Found+fixed latent B010 on the way.

## D013 — 2026-07-03 — 2-wide OoO microarchitecture (executed under the
## "all done" directive; decided by Claude, documented for review)

Full spec in docs/OOO.md. The five structural choices and their
alternatives:

1. **Rename: merged PRF (R10K)** over P6 values-in-ROB. One value copy,
   no ARF write traffic, the scheme modern cores use (interview value);
   costs a free list and freeing discipline. 64 physregs = 32 arch + 32
   in-flight (matches ROB depth, so renaming never starves before the
   ROB fills).
2. **Recovery: per-branch RAT checkpoints (8)** over ROB-walk (slow,
   variable latency) or retire-time RRAT squash (adds resolve-to-retire
   latency to every mispredict). A checkpoint is only ~220 bits on FPGA
   FFs; 8 in flight covers CoreMark's branch density. Checkpoints are
   freed at retire, so out-of-order branch resolution needs no special
   casing — nested restores always land on live older checkpoints.
3. **Issue: unified 16-entry queue** with select ≤3 (port-bound: ALU+br,
   ALU+CSR, mem) over split queues (more tuning knobs, more logic).
   Select-time tag broadcast for 1-cycle ops gives back-to-back
   dependents; loads broadcast at writeback because they can replay.
4. **Loads: conservative disambiguation** — issue only past
   known-address older stores, forward only exact full-word matches,
   replay past partial overlaps. Costs IPC vs speculative loads +
   store-sets, but eliminates the LQ, memory-order violations, and the
   replay-storm class of bugs. The LQ returns with speculation as its
   own measured stage.
5. **Stores commit at retire** (≤1/cycle) — keeps all MMIO side effects
   non-speculative for free.

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
