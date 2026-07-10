# Bug Log

Every real bug found in this project: symptom, root cause, how it was caught,
and the fix. Newest entries at the top.

Status legend: **OPEN** (not yet fixed) / **FIXED** (fix merged).

---

## B014 — store-set training captured a violation in the flush-at-head start cycle, then read a dead ROB entry — FIXED (2026-07-09)

- **Symptom:** with the D021 store-set predictor integrated (`LOAD_POLICY=2`),
  the riscv-test `ld_st` died on the new INV-P7 assertion:
  `"stset training reads a dead ROB entry"` (39/40 suites still green — this
  needs a violation CAM hit in one exact cycle).
- **Root cause:** predictor training is 2-phase (capture the violated pair's
  tag/PCs at the CAM-hit cycle N, apply the SSIT merge at N+1 via a
  `rob_pc[tag]` read — deliberately, so nothing is appended after the LQ CAM,
  the D020 critical path). The capture gate copied the poison write's
  wrong-path suppression (`restore_en && is_younger`) and blocked the drain
  (`!lq_flushing`) — but not `lq_flush_start` itself. When a store fills and
  CAM-hits some executed load **in the same cycle a poisoned load at the ROB
  head starts its flush**, the flush clears *every* `rob_v` at that edge, so
  the N+1 apply indexes a dead entry. `restore_en` can never cover this case:
  branch mispredicts are architecturally suppressed while a violation flush
  starts, which is exactly why the co-incident cycle needs its own gate term.
- **How caught:** the INV-P7 Verilator assertion added *with* the feature
  (docs/STORESET.md invariants) — one regression run, zero debugging. The
  assertion methodology paid for itself on its first outing.
- **Fix:** add `!lq_flush_start` to the capture gate. The dropped event is a
  genuine dependence pair that simply retrains on its next violation
  (hint-only state, bounded cost); `ld_st` and the full suites pass, and the
  strict INV-P7 assertion stays enforced rather than being weakened.

## B013 — OoO load-violation flush-at-head does not clear the issue queue (stale IQ entries re-issue) — FIXED (2026-07-08)

- **Symptom:** With speculative loads (D020, `SPEC_LOADS=1`), the official
  riscv-test `ld_st` failed in lockstep: the machine ran down the test's
  `fail` path (retired `pc=0xe68`) where the ISS expected `pc=0x48`. The
  directed `lq_violation.S` and the 25 plain random seeds all passed, so the
  poison + flush-at-head recovery *looked* correct; only a dense
  store→same-address stream tripped it.
- **Root cause:** the load-ordering-violation flush-at-head must empty the
  **whole** issue queue (every resident uop is younger-or-equal to the
  poisoned load at the ROB head). The IQ was flushed by *reusing the
  branch-mispredict path* with `flush_tag = head_tag - 1`, intending "every
  entry is younger than head−1, so clear all." But the age predicate is
  `(u.tag − head_tag) > (flush_tag − head_tag)`, and `(head_tag−1) − head_tag
  = 6'd63`; a resident entry's relage is a 6-bit value in `[0,63]`, so
  `relage > 63` is **never true**. The violation flush therefore cleared
  **zero** IQ entries. After the freelist/RAT rebuild refetched the load's PC
  and re-dispatched, the surviving pre-flush IQ entries (same ROB tags,
  reused this round) re-issued with their **old** `ps1`/`ps2` — physical
  registers since reallocated to unrelated values. A branch dependent on the
  re-read load then resolved twice (once correct, once on the stale copy) and
  the stale copy mis-redirected to `fail`. The SQ (`commit_tail4`) and LQ
  (`flush_all`) already had proper unconditional clears; only the IQ relied on
  the arithmetically-impossible `head_tag−1` trick.
- **How caught:** golden-model lockstep pinned the retired PC (`0xe68` vs
  `0x48`); a cycle-stamped RTL trace (`+define+LQ_TRACE2`, temporary) then
  showed the *same* ROB tag issuing twice with different `ps1`/`ps2` after the
  flush — a survived-IQ-entry signature, not the pre-flush-branch race the
  WIP handoff had hypothesized.
- **Fix:** give `ooo_iq` a dedicated `flush_all` port that unconditionally
  clears every `v[i]`, driven by `lq_flush_start` (taking priority over the
  tag-relative branch squash). Removed the broken `head_tag−1` argument;
  `flush_en`/`flush_tag` now carry only the branch mispredict. `ld_st` passes
  (928 instrs lockstep-clean, ~49 real violation+recovery events); full OoO
  suite green (14/14 + 40/40 + 25/25 + new 25/25 `--vio` stress with 1185
  violations). IPC-neutral: the plain random seeds are byte-identical and
  CoreMark is unaffected by the fix path (violations are rare there).

## B012 — Synchronous fetch loses the stalled instruction (fetch register not held) — FIXED (2026-07-07)

- **Symptom:** After moving the in-order core to synchronous instruction
  memory (B006), directed ALU/branch/jump tests still passed, but `hello.c`
  and the NPU tests diverged in lockstep: the retired PC and the retired
  instruction disagreed (e.g. `pc=0x64` writing `x10` when the instruction
  at `0x64` writes `x31`). Failures only appeared on tight load-use pairs
  and the NPU EX-hold — the cases that stall Decode.
- **Root cause:** With the fetch fold, imem's registered output *is* the
  Decode instruction, but imem's read address (`pcF`) is one instruction
  ahead of the Decode slot. Freezing the PC on a stall is not enough: the
  fetch register keeps latching `mem[pcF]` (the *next* instruction), so the
  stalled instruction is overwritten by its successor while IF/ID still
  holds the old PC → PC/instruction misalignment.
- **How caught:** golden-model lockstep co-sim, first mismatch reported the
  diverging PC — pinpointing a fetch/decode alignment issue, not a decode bug.
- **Fix:** give imem's synchronous read register a `hold` enable that
  mirrors the IF/ID stall (`stallD | npu_stallE`); when Decode is frozen the
  fetch register freezes with it. IPC-neutral (mispredict penalty stays 2).
  The existing `hello.c` + NPU suites already exercise it.

## B011 — In-order NPU EX-hold recomputes address/data from decaying forwarding muxes — FIXED (2026-07-03)

- **Symptom:** none in the merged suites — caught pre-merge. With the
  B011 shape (`sw GO→CTRL; addi t3,t0,0x40; lw t4,0(t3)`) the held load
  performed a dmem read at a garbage address: lockstep divergence, or
  silently wrong data with lockstep off.
- **Root cause:** the D014 EX-stage stall froze PC/IF-ID/ID-EX but let
  MEM and WB drain (deliberately, to avoid re-executing side effects).
  The held access's address (`alu_resultE`) and store data
  (`rs2_fwd_base`) were recomputed combinationally every held cycle from
  the forwarding muxes — whose sources are exactly the draining MEM/WB
  stages. Two cycles into the hold the producer was gone, the muxes fell
  back to the stale decode-time ID/EX regfile copies, the address left
  region 0x5, `npu_stallE` self-released, and the access escaped to
  dmem/MMIO while the array was busy. Store data decayed the same way.
- **How caught:** adversarial design review of the NPU stage (workflow,
  finding confirmed by a simulation reproducer) — compiled C never hits
  the shape because gcc hoists MMIO base addresses far from the access.
- **Fix:** snapshot `alu_resultE`/`rs2_fwd_base` into hold registers on
  the FIRST stall cycle (forwarding is live there by construction); the
  stall decision and the values EX/MEM finally latches use the snapshot.
  New assertion: a hold may release only because the array went idle.
  Directed regression `sw/tests/npu_ordering.S` catches it pre-fix (the
  release assertion fires on the very first held load; without
  assertions the C readback returns dmem garbage, code 2) and passes
  post-fix on both cores — verified both ways by temporarily reverting
  the snapshot muxes.

## B010 — OoO SQ forwarding shadows MMIO reads (latent lockstep divergence) — FIXED (2026-07-03)

- **Symptom:** none yet observed — latent. A load from an IO word with an
  older, still-queued store to the SAME word (e.g. `sw` to the LED
  register followed closely by `lw` from it) would forward the raw store
  word from the SQ instead of reading the device register. The ISS reads
  the device (LEDs are masked to 10 bits; switch-register stores are
  dropped entirely), so the first program to do this would have died with
  a lockstep mismatch — or worse, worked in sim and misbehaved on HW.
- **Root cause:** in `ooo_cpu.v` the load-value mux gave `sq_qhit`
  priority over the `p2_isio` device-read path. Store-to-load forwarding
  is a RAM concept; for device registers the store's side effect (mask,
  drop, trigger) is applied by the device, so the forwarded raw word is
  simply not the value a program-order read returns.
- **How caught:** design review of the NPU integration (D014) — the NPU's
  read-back registers made the same-word store→load case a certainty
  instead of a curiosity.
- **Fix:** IO-region loads (0x4 and 0x5) replay until every older store
  has drained from the SQ (new `q_older` output; existing replay path).
  When such a load finally performs, an SQ hit is impossible by
  construction — asserted in sim. Covered by `sw/ctests/npu_basic.c`
  (write→read-back sequences) under lockstep on both cores.

## B009 — OoO store queue never allocates a slot1-only store — FIXED (2026-07-03)

- **Symptom:** first OoO regression: `store_fwd` load returns 0 instead
  of the stored 42; `hello.c` diverges with a store to the WRONG address
  (stream desync) 36 instructions in.
- **Root cause:** in `ooo_sq.v` the slot1 allocation was nested INSIDE
  `if (alloc0_en)` — a store dispatching in rename slot1 beneath a
  non-store slot0 never allocated its SQ entry. Its later address/data
  fill landed in a dead slot, the store silently vanished from memory,
  and loads read stale data.
- **How caught:** golden-model lockstep, first OoO bring-up run — both
  failures pinpointed to the exact retiring instruction. Fix-to-diagnosis
  took minutes; without lockstep this class of bug surfaces as a wrong
  CoreMark CRC millions of cycles later.
- **Fix:** SQ allocation interface reworked to `alloc_n` (0..2 entries at
  tail/tail+1); store uop positions computed in the top from the tail tag
  and slot pairing. Verified by the full lockstep suite (9 directed +
  40 ISA + 25 random) and CoreMark.

## B008 — Register file lacks write→read bypass (distance-3 RAW reads stale) — FIXED (2026-07-03)

- **Symptom:** `sw/tests/store_fwd.S` kept failing *after* the B007 fix:
  the store wrote correct data, but the later `beq` compared against 0.
- **Root cause:** A consumer exactly **3 instructions** behind its producer
  reads the register file in ID during the same cycle the producer writes
  it back in WB. The write commits on the clock edge, the read is
  combinational — so ID sees the stale value. One cycle later the producer
  has left WB, so the EX forwarding unit (which covers distances 1–2 via
  MEM/WB) no longer matches either. Classic missing "write-first" regfile
  semantics. In the failing test the *load address* register was
  distance-3, so the load read address 0 and returned 0.
- **How caught:** `+verbose` harness tracing: forwarding fired correctly
  (`fwdA=1, rdW=x8, MemToRegW=1`) but `mem_dataW=0` — pointing past the
  forwarding unit to the load address, then to the ID-stage regfile read.
- **Fix:** Internal bypass muxes on both regfile read ports
  (`rd_data` when `reg_write && rd_addr==rs_addr && rd_addr!=0`).
  Alternative considered: writing the regfile on the falling edge
  (Harris & Harris style) — rejected because dual-edge clocking complicates
  FPGA timing closure.

## B007 — Store data is not forwarded (stale value stored) — FIXED (2026-07-03)

- **Symptom:** `add x7,...` immediately followed by `sw x7, 0(x1)` stores
  the OLD value of x7.
- **Root cause:** The forwarding muxes only feed the ALU operands. EX/MEM
  latches `rs2_dataE` (the raw ID/EX value) as store data, so a store's
  data operand bypasses forwarding entirely. For SW, ALUSrc=1 selects the
  immediate, so the forwarded `rs2_fwd_base` is computed and then unused.
- **How caught:** Writing the first smoke test (2026-07-03) — had to
  deliberately distance the store-data write from the SW to make the test
  independent of this bug.
- **Fix:** EX/MEM latches `rs2_fwd_base` instead of `rs2_dataE`
  (decision D011/F1). Directed test `sw/tests/store_fwd.S` fails before
  the fix (code 2, stale store) and passes after. Fixing it exposed B008.

## B006 — Memories synthesize to flip-flops instead of block RAM — FIXED (2026-07-10)

- **Final update (2026-07-10, decision D022) — real root cause found:** the
  three-session "MIF is not supported for the selected family" wall was
  never a family limitation. MAX 10 keeps M9K init images in its internal
  configuration flash, and the project had no ERAM-capable
  internal-configuration mode selected; Quartus therefore rejected EVERY
  init path (inferred `$readmemh` ROM, `ram_init_file` attribute — which
  bakes contents into logic instead — and explicit altsyncram, which
  finally names the true error: **16031 "Current Internal Configuration
  mode does not support memory initialization or ROM. Select Internal
  Configuration mode with ERAM"**). Fix: one QSF line,
  `INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"`, plus explicit
  altsyncram ROMs in `rtl/mem/imem_banked.v` (even/odd banks, D022). The
  OoO board top's imem is now **4 M9Ks + 55 LEs** (was a logic ROM), fit
  48,153/49,760 LEs, `.sof` rebuilt. **How caught:** a bare-module proof
  project with a high-entropy 1024-word MIF (so the ROM couldn't
  constant-fold) — the led_demo image folds to ~100 LEs and had masked the
  whole issue by making imem look cheap. The in-order core's single-port
  imem stays a logic ROM by choice (not the board top; its D016 fold is
  tagged and hardware-confirmed). dmem was already block RAM since D016.

- **Update (2026-07-07, decision D016):** in-order core reworked to
  synchronous-read memories. **dmem now infers block RAM** (Quartus 20.1
  A&S: `altsyncram`, byte-lane split; dedicated logic registers 12,499 →
  5,472). **imem is still logic**: Quartus refuses to map an auto-inferred,
  *initialized* ROM to M9K on MAX 10 ("MIF is not supported for the selected
  family"). imem is now structurally M9K-ready (registered read); finishing
  it needs an explicit `ram_init_file` (.hex/.mif) and is deferred to the
  on-board large-program stage. The synchronous fetch already removes the
  async instruction-read critical path (the part B005 timing needs).
  IPC-neutral on both memories; verified in-order + OoO lockstep.
  Original report below.

## B006 (original) — Memories synthesize to flip-flops instead of block RAM

- **Symptom:** Fitter report (2025-12-01) shows 12,499 logic registers and
  **0 block-RAM bits**. `dmem` alone costs ~8,200 FFs; regfile, BHT and BTB
  are also register arrays.
- **Root cause:** Combinational (same-cycle) reads and the async-reset init
  loops prevent Quartus from inferring MAX 10 M9K blocks, which require
  synchronous read.
- **How caught:** Reading `output_files/hanna_cpu.fit.summary` during the
  initial codebase exploration (2026-07-02).
- **Fix:** Restructure memories for synchronous read (pipeline implication:
  imem/dmem gain a 1-cycle latency — needs an architectural decision).
  Deferred to the RV32I-completion / memory rework stage.

## B005 — Design fails timing on the ripple-divided clock — FIXED (2026-07-07)

- **Symptom:** Setup slack −13.05 ns on the `div[25]` clock domain, −2.36 ns
  on CLOCK_50 (sta.summary, 2025-12-01). Works on the board only because the
  demo clock is ~0.75 Hz.
- **Root cause:** CPU is clocked by bit 25 of a free-running counter register
  (a "ripple" clock) rather than a PLL output; no meaningful timing
  constraints (.sdc) exist.
- **How caught:** Reading the STA summary during exploration (2026-07-02).
- **Fix (decision D017):** MAX 10 ALTPLL turns CLOCK_50 into a clean CPU
  clock (`rtl/top/pll.v`), core held in reset until PLL lock; ripple divider
  removed. Added the first real `.sdc` (`create_clock` + `derive_pll_clocks`
  + `derive_clock_uncertainty`, async false-paths). LED demo now paces
  itself in software (`sw/demo/led_demo.S`). **Result:** Quartus 20.1 STA
  slow-85C **Fmax = 53.95 MHz**, meets 50 MHz with **+1.466 ns** setup slack,
  0 unconstrained clocks/ports (was −13.05 ns). Made closable by the
  synchronous BRAM memories (B006/D016) removing the async memory paths.

## B004 — ADDI with imm[11:5] = 0100000 executes as SUB — FIXED (2026-07-03)

- **Symptom:** `addi rd, rs1, imm` for imm in 1024–1055 subtracts instead of
  adds.
- **Root cause:** The Dec-10 fix for B003 routes I-type ALU ops through
  `ALUOp=2'b10`, where `alu_control` checks `funct7 == 0100000` to detect
  SUB. For I-type instructions instr[31:25] is *immediate bits*, not funct7,
  so certain immediates spoof the SUB encoding. `alu_control` needs an
  "is I-type" input (or funct7 masking) so SUB detection only applies to
  R-type (and later, SRAI's shamt[10] special case).
- **How caught:** Code review of `control.v` + `alu_control.v` during repo
  verification (2026-07-03).
- **Fix:** Decision D006/A2 — flattened funct3-based decode where the
  I-type class ignores funct7 except for the ISA-defined SRLI/SRAI bit.
  Regression check 2 in `sw/tests/alu_ops.S` (`addi x5, x0, 1024`)
  reproduces the spoof pattern.

## B003 — ANDI/ORI/XORI/SLTI executed as ADD — FIXED (2025-12-10, by Hanna)

- **Symptom:** All I-type ALU instructions except ADDI computed `rs1 + imm`.
- **Root cause:** `control.v` set `ALUOp=2'b00` (forced ADD) for opcode
  0010011 instead of decoding via funct3.
- **How caught:** Present in the 2025-12-01 local snapshot; fixed in the
  version uploaded to GitHub on 2025-12-10 (`ALUOp=2'b10` for I-type).
- **Fix:** Merged in commit `0815273` ("Update control.v"). Note: the fix
  introduced B004.

## B002 — Demo program never reaches the LED MMIO address — FIXED (2026-07-03)

- **Symptom:** The hardcoded imem program comments claim
  `slli x2, x2, 28 → x2 = 0x40000000`, but the ALU has no shifter — SLLI
  (funct3=001) falls into `alu_control`'s default ADD, so x2 = 4 + 28 = 32.
  The `sw` then writes RAM address 0x20, not the LED register.
- **Root cause:** Shift instructions are not implemented anywhere in the ALU
  path; the demo program assumed they were.
- **How caught:** Instruction-by-instruction trace of `imem.v` against
  `alu_control.v` during exploration (2026-07-02).
- **Fix:** Shifts implemented with the A2 decode rework. Verified in
  simulation: the demo now stores an incrementing count to 0x40000000
  (the LED register) — the FPGA demo will show a binary LED counter for
  the first time.

## B001 — Repo did not compile: dangling debug_x3 connection — FIXED (2026-07-03)

- **Symptom:** Elaboration error in any tool: `cpu_pipeline.v` connects
  `.debug_x3(...)` on `register_file`, but the uploaded `register_file.v`
  has no such port.
- **Root cause:** Files were uploaded to GitHub individually via the web UI
  from mixed working copies — `register_file.v` came from a copy where the
  debug port had been removed, `cpu_pipeline.v` from one where it hadn't.
- **How caught:** Cross-checking every repo file against the last known-good
  local Quartus build during repo verification (2026-07-03).
- **Fix:** Removed the dead debug wire and connection (commit on
  `restructure` branch). LEDs are MMIO-driven, so no functionality lost.

---

## Known non-bug quirks (watch list)

- ~~BNE decodes as BEQ~~ — resolved 2026-07-03 by the dedicated branch
  unit (D007/B2): all six conditions decoded from funct3, each covered
  taken/not-taken in `sw/tests/branch_ops.S`.
- ~~dmem indexes with full `addr[31:2]`~~ — resolved 2026-07-03: imem and
  dmem now index with an explicit `$clog2(DEPTH)`-wide slice (aliasing is
  deliberate and documented).
- **Spurious hazards from immediate bits:** the hazard/forwarding units
  compare the rs1/rs2 *fields* of every instruction, including formats
  where those bits are immediate data (e.g. I-type rs2 field, LUI rs1
  field, and — since D012 — the zimm of CSRRWI/CSRRSI/CSRRCI, which lives
  in the rs1 field). Worst case is an unnecessary 1-cycle load-use stall —
  a small IPC leak, never a correctness issue. Fix by decoding
  rs1/rs2-valid flags; measure the IPC delta when CoreMark runs.
- **MMIO registers are word-access-only:** sub-word loads/stores to
  0x4xxxxxxx bypass the dmem lane logic and hit the raw MMIO registers.
  C code must use `volatile uint32_t*` for MMIO (normal practice). Same
  quirk for the NPU region 0x5xxxxxxx (covered by `npu_basic.c`).
- **OoO IO loads are not ordered against older IO loads** (noted during
  the D014 review): two loads of the SAME IO register can complete out
  of program order when the older one's operands arrive late — an RVWMO
  same-address read-read coherence violation, observable only for
  externally-mutable registers (today: switches @ 0x40000004; all NPU
  registers change only via this hart's stores, so the NPU is immune).
  Zero effect in sim (switches tied to 0). The proper fix is load-load
  age tracking — arrives with the LQ / speculative-loads stage.
