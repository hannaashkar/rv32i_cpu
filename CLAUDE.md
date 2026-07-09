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
- **ISA: full RV32I user-level compute + Zicsr** — all ALU ops + shifts,
  SLTU/SLTIU, all six branches, JAL/JALR, LUI/AUIPC, LB/LBU/LH/LHU/LW,
  SB/SH/SW, CSRRW/S/C(+I). Compiled C can run. Still missing: FENCE (safe
  to treat as NOP), ECALL/EBREAK/traps, M ext.
- CSRs (D012): `csr_file` executes CSR ops in EX (nothing at EX can be
  killed → writes commit safely); read returns via the EX result mux; CSR
  address rides immE[11:0]. Implemented: cycle/cycleh, instret/instreth
  (read-only; writes dropped until traps), mscratch (R/W). instret counts
  a 1-bit `valid` flag flowing IF→WB (flushes/bubbles clear it) — exact
  retirement counting; sim prints `cycles/instret/ipc` at exit from the
  same counters software reads.
- Tests: `make regress` = 8 directed suites in `sw/tests/` (ALU incl. B004
  regression, branches, jumps incl. BTB-stale return, LUI/AUIPC, sub-word
  memory lanes/sign, store-forwarding, CSRs incl. exact instret deltas,
  smoke). All green.
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

**2026-07-03 (later still)** — Zicsr scaffold + measurement counters
(branch `csr-counters`, decision D012 — Hanna chose full scaffold +
valid-bit retirement over the minimal options):
- New `rtl/core/csr_file.v`: all six CSR forms execute in EX; cycle/
  instret (64-bit, read-only) + mscratch (first writable CSR, proves the
  write path). Unimplemented CSRs read 0; writes to read-only CSRs are
  dropped until traps exist.
- 1-bit `valid` flag added through all four pipeline regs; flushes and
  bubbles clear it; instret increments on valid-at-WB. Exact by
  construction — `sw/tests/csr_ops.S` checks instret deltas across a
  deliberately-mispredicting loop (delta 15 exactly, 18 checks total).
- Harness now prints `cycles/instret/ipc` at exit from the hardware
  counters. Software builds with `-march=rv32i_zicsr`.
- `make regress`: 8/8 green; quartus_map 0 errors / 9 warnings (unchanged).

**2026-07-03 (evening)** — C runtime live (branch `c-runtime`):
- `sw/common/`: crt0.S (sp/gp/bss setup, exit protocol: main()==0 → PASS),
  link.ld (Harvard layout: text @ 0 in imem, data @ 0x10000000 in dmem —
  aliases to dmem word 0; `.dmem_origin` sentinel pins the extracted data
  image even when .rodata is empty), rv32.h (MMIO + rdcycle/rdinstret
  helpers), libmin.c (memcpy/memset/str* for freestanding gcc).
- Makefile: `sw/ctests/*.c` → elf (crt0+libmin+`-lgcc` for __mulsi3/
  __divsi3) → split `.text.hex` + `.data.hex`; `make regress` runs C tests
  with `+imem=`/`+dmem=`; `make run PROG=x DMEM=y` for manual runs.
- **First compiled C program passes**: `sw/ctests/hello.c` (recursion,
  soft mul/div, all data sections, string ops) — 2100 cycles, 1880
  instret, IPC 0.895. Regression now 9/9. No RTL touched in this stage.

**2026-07-03 (night)** — CoreMark baseline measured (branch `coremark`);
**Task 1 complete, tagged `v1.0-inorder-baseline`**:
- EEMBC CoreMark vendored unmodified in `sw/coremark/` (Apache-2.0), port
  layer in `sw/coremark/rv32/`: clock = rdcycle, ee_printf → sim-console
  MMIO (0x40000010) snooped by the harness — zero RTL change, no-op on HW.
- `make coremark` = 600-iteration official-rules run (≥10 simulated
  seconds at 50 MHz), pass gate = the three official CRCs.
- **Baseline: 1.177 CoreMark/MHz, IPC 0.849** (510.1M cycles, 432.9M
  instret, "Correct operation validated") — full context, caveats, and
  reproduction commands in docs/BASELINE.md. Regression 9/9 throughout.

**2026-07-03 (late night)** — Hanna lifted the review gates ("ignore my
rule, start the next phases, I want all done") — phases executed
autonomously, every decision logged in DECISIONS.md:
- **Verification phase** (pulled forward — the OoO core needed it):
  golden-model lockstep co-sim (tb/verilator/iss.h, on by default for
  every run), official riscv-tests rv32ui 40/40, constrained-random
  generator 25 seeds × 3000 instrs. docs/VERIFICATION.md. `make verify`.
- **2-wide OoO core** (branch `ooo-core`, D013, docs/OOO.md is the spec):
  R10K-style merged PRF (64), RAT + freelist + 8 per-branch checkpoints,
  ROB 32 (2-wide dispatch/retire), unified IQ 16 (select ≤3: br/ALU/mem,
  select-time wakeup, EX bypass net), SQ 8 (fwd exact-word, replay on
  partial overlap, commit at retire), gshare 1024 + BTB 64 + RAS 8 with
  decode-redirect for JAL/ret, CSRs serialized. Shared alu/branch_unit/
  csr_file/memories (r/w ports split; in-order top unchanged, re-verified).
  First OoO bug B009 (SQ slot1 alloc) found by lockstep in minutes.
  **Result: IPC 1.008 vs 0.849, CoreMark/MHz 1.397 vs 1.177 (+18.8%),
  432.9M instructions lockstep-verified, zero divergence.** All suites
  green on BOTH cores; quartus_map 0 errors with all OoO RTL included.
  FPGA top remains cpu_pipeline until the timing/PLL stage (B005).

**2026-07-03 (NPU stage, branch `npu-array`, decisions D014/D015,
docs/NPU.md is the spec)**:
- `rtl/npu/`: 4×4 int8 **output-stationary systolic array** (npu_pe /
  npu_array / npu_top), MMIO region 0x5xxx_xxxx, tile-accumulate across
  GO commands (K tiling), 10-cycle pass, reads side-effect-free. Unit TB
  (`make npu-tb`): 2000 random accumulation chains vs C++ golden — PASS.
- **Hardware ordering interlocks, software never polls**: OoO core —
  IO-region loads replay until every older store drains (new SQ
  `q_older`) and (region 5) `busy_next` clears; SQ drain backpressures
  into a busy NPU (`mw_ready`/`mw_fire`; harness snoops `mw_fire`).
  In-order core — NPU accesses stall in EX on `busy_next` (id_ex_reg
  gained a stall-wins-over-flush input) with address/data SNAPSHOTTED at
  hold entry. Found+fixed latent **B010** (SQ forwarding shadowed MMIO
  reads) and **B011** (EX-hold operand decay — critical, caught by the
  adversarial review workflow pre-merge, regression
  `sw/tests/npu_ordering.S` + release assertion added).
- **ISS mirrors the NPU** (instantaneous at the GO store — exact because
  busy is architecturally unobservable): every NPU access in every test
  is lockstep-compared. Regression + riscv-tests + random: all green on
  BOTH cores incl. two new NPU ctests (register semantics + random
  tiled GEMMs).
- **Quantized MNIST MLP end-to-end** (`scripts/train_mlp.py`, numpy,
  seeded): 784→32→10, symmetric int8, TFLite-style requant — 97.10%
  float / **97.13% integer** on the full 10k test set. On-core
  (`make npu-mlp[-ooo]`): soft int8 path vs NPU path bit-exact, 32/32
  images correct, **speedup 85.99× in-order / 55.89× OoO** (soft 96.4M
  vs NPU 1.12M cycles; OoO soft 58.5M vs 1.05M — its IPC on the mul-
  heavy soft path is 1.54). ~92M instructions lockstep-verified per run,
  zero divergence.
- quartus_map: **0 errors**, 16 DSP elements (the PE multipliers), 24812
  LEs total with both cores + NPU in the tree. Real-board MLP demo needs
  B006 (BRAM) first — speedups above are simulation-measured
  (SIM_BIG_MEM), same methodology as the CoreMark baseline.

**2026-07-07** — FPGA bring-up path for the in-order core: B006 (BRAM) +
B005 (timing) done (branch `bram-mem-sync`, decisions D016/D017; Hanna
chose in-order-first + minimal/stall latency + PLL/SDC):
- **B006 — synchronous-read memories (IPC-neutral fold).** dmem/imem gained
  a `SYNC_READ` param; in-order core opts in, OoO keeps combinational reads
  (unchanged). The one BRAM read-latency cycle is absorbed by folding the
  existing IF/ID instruction latch and MEM/WB mem-data latch into the
  memories' own read registers — load-use, forwarding and the 2-cycle
  mispredict penalty are all unchanged. **dmem now infers block RAM**
  (altsyncram; dedicated logic registers 12,499 → 5,472). imem stays logic
  (MAX 10 won't MIF-init an auto-inferred ROM) but is M9K-ready and off the
  async path; full imem block-RAM via `ram_init_file` deferred to the
  on-board large-program stage. **B012** found+fixed by lockstep: sync
  fetch dropped the stalled instruction until imem got a `hold` enable
  mirroring the IF/ID stall.
- **B005 — PLL + real .sdc.** `rtl/top/pll.v` (MAX 10 ALTPLL, CLOCK_50 →
  50 MHz clean clock + locked); de10_top reset held to PLL lock, ripple
  divider gone; first real `.sdc` (create_clock + derive_pll_clocks +
  uncertainty + async false-paths). **STA slow-85C Fmax = 53.95 MHz, meets
  50 MHz with +1.466 ns slack** (was −13.05 ns), 0 unconstrained paths.
  Self-paced LED walker (`sw/demo/led_demo.S`) replaces the slow-clock demo.
- Verified: in-order **and** OoO each 12/12 regress + 40/40 riscv-tests +
  25/25 random seeds, lockstep clean. Quartus fitter 0 errors. `.qsf` pins
  untouched (only pll.v + .sdc file-list entries added). **Branch not yet
  merged to main / not pushed** — pending Hanna's review.

**2026-07-07 (later)** — both cores now demonstrated on the DE10-Lite:
- **In-order core HARDWARE-CONFIRMED** at 50 MHz: `bram-mem-sync` merged to
  main + pushed + tagged **`v3.1-inorder-fpga`**; the self-paced LED walker
  runs live (block-RAM dmem, PLL, timing-closed). First on-silicon demo past
  the CoreMark baseline.
- **OoO core board port** (branch `ooo-bram-port`, D018, **NOT merged** —
  main stays in-order): ooo_cpu got the same IPC-neutral dmem `SYNC_READ`
  load fold (lockstep-clean 12/12+40/40+25/25); de10_top switched to
  ooo_cpu. **OoO Fmax = 8.42 MHz — critical path entirely in the issue-queue
  select+wakeup** (`ooo_iq` u[0]→r2, ~118 ns; the classic OoO limiter, not
  imem/dmem). Clocked at **7.14 MHz** (PLL /7), timing MET +9.35 ns, dmem
  block RAM (103 segments); the OoO walker runs live on the board (~1.7 s/
  step). **Lesson: perf = IPC × Fmax** — OoO's +18.8% IPC is stranded by its
  7× lower Fmax here (~6× slower wall-clock), until the scheduler is
  pipelined.

**2026-07-08** — branch `ooo-iq-pipeline` → **MERGED to `main` + pushed**
(merge commit `dbc0ecc`, `--no-ff`; Hanna overrode the hands-only rule and
approved the merge). **The merge FLIPPED the FPGA board top: `de10_top` now
instantiates `ooo_cpu` @ 16.67 MHz (PLL /3), NOT the in-order core @ 50 MHz
(tag `v3.1-inorder-fpga`).** Hanna chose this knowing OoO is ~6× slower
wall-clock on the board (perf = IPC × Fmax). Both cores remain fully verified on
merged main (in-order 14/14+40/40+25/25; OoO 14/14+40/40+25/25+25/25 `--vio`;
`quartus_map` 0 errors). Contents:
- **Task 1 DONE (D019): OoO issue-queue select pipelined.** `ooo_iq.pick()`
  rewritten from a 16-deep serial min-chain to a balanced log-depth tree
  (bit-identical grant via lower-index tie-break) + parallel port-1 select.
  **STA Fmax 8.42 → 19.65 MHz (2.33×), IPC bit-identical** (12/12+40/40+25/25
  lockstep-clean; hello.c 1914/1882 unchanged). Board PLL /7→/3 = 16.67 MHz,
  timing MET +18.9 ns, 44,422 LEs. New limiter = the wakeup path (scan gone).
  Honest: OoO still needs ~42 MHz to tie in-order's 50 MHz — the true 2-stage
  pipelined scheduler is the deferred next step (Hanna chose "bank 19.65").
  Design adversarially verified before coding (naive "register the grant"
  split rejected: it costs 1 bubble/pair).
- **Task 2 DONE (D020): speculative loads + load queue.** `ooo_lq.v` (8-entry
  LQ + store→younger-load violation CAM), `SPEC_LOADS=1` relaxes the
  conservative load gate for RAM loads (IO/NPU keep strong ordering), aRAT +
  `rob_poison` + multi-cycle flush-at-head "Strategy B-real" recovery (a
  violated load owns no checkpoint → `rat<=arat` + per-cycle freelist rebuild).
  **The `ld_st` failure was B013, NOT the WIP handoff's hypothesis:** the
  violation flush never cleared the IQ — it reused the branch path with
  `flush_tag=head_tag−1`, but the 6-bit relage predicate makes `>63` always
  false → ZERO entries cleared → stale pre-flush IQ entries re-issued with
  reallocated phys regs. Fix = a real `flush_all` port on `ooo_iq`
  (`lq_flush_start`). **Verified:** OoO 14/14 regress + 40/40 riscv-tests
  (incl. `ld_st`, ~49 violation+recovery events) + 25/25 random + a new 25/25
  `--vio` stress suite (1185 real violations), all lockstep-clean; in-order
  untouched (14/14+40/40+25/25). **IPC is governed by violation frequency
  because the flush-at-head recovery is a heavy ~46-cyc drain: CoreMark
  (violations rare) IPC 1.026 spec vs 1.006 cons = +2.0%; hello.c (15 stack-
  spill violations / 1882 instr) 2613 cyc spec vs 1921 cons = −36%.** Both
  CRC/lockstep-clean. NET win needs violation-sparse code — **open Hanna call:
  keep SPEC_LOADS=1, default off, or add a store-set predictor to stop
  re-speculating a load that violated** (see D020). **Fmax 26.32 MHz** slow-85C (bare `ooo_cpu`
  top, 48,238 LEs/97%, 16 DSP) — the LQ CAM did NOT erode the D019 wall
  (crit path = load-uop→CAM→`rob_poison`, still clocks above the wakeup
  limiter). `ooo_lq.v` added to `synth/rv32i_cpu.qsf`; `make regress-rand-vio`
  + `verify-ooo` updated. `docs/LQ_WIP_HANDOFF.md` marked DONE.
- **Build gotcha:** Verilator builds SILENTLY FAIL without
  `VERILATOR_ROOT=…/ucrt64/share/verilator` exported.

**2026-07-10** — branch `ooo-store-set`: **D021 store-set memory-dependence
predictor (Chrysos & Emer, ISCA '98) — the D020 open call resolved.** Hanna
approved a fully autonomous run ("industry-standard fix, god-tier mode").
`docs/STORESET.md` is the binding spec; DECISIONS.md D021 has the full entry.
- **Mechanism:** new `rtl/ooo/ooo_stset.v` — SSIT 64×{v,ssid[3:0]} on
  pc[7:2] + LFST 16×{v,sqpos[2:0]}; the whole predictor is a *dispatch-time
  mask policy* (the IQ's existing 8-bit store-wait masks). `LOAD_POLICY`
  param on ooo_cpu: 0=conservative / 1=always-speculate (both verified
  cycle-identical to D020) / **2=store sets (shipping default)** / 3=Alpha
  21264 1-bit stWait (built for honest comparison). Safety bracket INV-P1:
  predicted mask is ANDed with the conservative mask → every wait lies
  between the two verified D020 extremes; tables are pure hints (lockstep-
  invisible). In-set store→store ordering (livelock fix), slot1 same-cycle
  LFST bypass (co-dispatched sw/lw spill pairs), 2-phase training off the
  LQ-CAM cycle (zero logic after the D020 critical path), 2^16-cycle decay.
- **Measured (4-policy table in D021): hello.c 2613 → 1989 cyc (90% of the
  D020 regression recovered, violations 15 → 1), CoreMark IPC 1.026 KEPT
  (421.77M cyc, official CRCs), `stset_precise.S` pointer-chase microbench:
  store sets 609 vs 21264-1-bit 698 (−12.7%) vs conservative 618 vs
  speculative 2149.** `ld_st` violations 49→31 (rest are single-shot sites
  no PC predictor can help). New directed suites: stset_predict / stset_pair
  / stset_precise.
- **B014 found+fixed by its own assertion** (INV-P7 training-liveness): a
  CAM hit in the exact `lq_flush_start` cycle trained against a ROB entry
  being cleared that edge; capture gate needs `!lq_flush_start`.
- **Verified:** unit TB (golden model, 200k random cycles, also passes with
  the SSIT_AW=5 escape) + OoO 17/17 + 40/40 riscv-tests + 25/25 random +
  25/25 --vio, all lockstep-clean, new invariant assertions armed (subset/
  onehot/no-self-wait/mask⊆live-unknown/training-liveness/ROB watchdog);
  policies 0/1/3 spot-regressed; in-order untouched. Two adversarial reviews
  (Verilog semantics + µarch corners): 0 confirmed defects.
- **STA (bare-core char, seed 3 of 5 — the device is at its 96-97% capacity
  cliff, 4 attempts failed to place; SSIT=32 trial also failed → table size
  doesn't decide the fit):** 48,302 LEs (97%), net +64 LEs/+160 regs vs
  D020. **Predictor NOT on the critical path** (lookup chain 19.2 ns ≈
  50 MHz-capable; core Fmax 19.55 MHz set by the pre-existing dmem-load→
  bypass→JALR→BTB path, 80% routing at the congested fit — the drop vs
  D020's 26.32 is fit-luck, not predictor logic).
- **⚠ BOARD FINDING (pre-existing, NOT from this branch):** a full board
  compile (first since D019) shows `de10_top` **no longer fits the 10M50**:
  predictor-free `main` maps to **51,225 LEs = 103%** of the device (with
  predictor: 53,075 = 107%); the fitter fails "Can't fit" at 96% after
  packing. The board has been over capacity since D020's LQ merged (that
  gate was map-error-count only, which misses capacity). **Task 3
  (imem→M9K) is now REQUIRED for any board bitstream** — the 4 KB
  logic-ROM imem burns the ~4-5k LEs that would fix this. The last
  buildable board top remains D019 (44,422 LEs) / tag `v3.1-inorder-fpga`
  for the in-order core.

**Next**: (1) **imem block-RAM via `ram_init_file`** (even/odd single-port
banks) — now **REQUIRED** to rebuild any board `.sof` (see board finding
above), and it unlocks the on-board MLP demo (Task 3). (2) **On-board
bring-up of the merged OoO top** — needs (1) first; then flash the `.sof`,
confirm the LED walker runs at 16.67 MHz (the board top is OoO with the
predictor in the tree). (3) The
2-stage pipelined scheduler (to beat in-order on HW; needs ~42 MHz) remains
a separate future project. (4) Optional: store-set telemetry CSR (violation
counter) for on-board measurement. **Env note:** riscv-gcc under MSYS make
needs TMP/TEMP/TMPDIR passed as **make variables** in **backslash** Windows
form (else `Cannot create temporary file in C:\WINDOWS\`); exported shell
vars don't reach the recipe. Verilator builds SILENTLY FAIL without
`VERILATOR_ROOT=…/ucrt64/share/verilator` exported.
