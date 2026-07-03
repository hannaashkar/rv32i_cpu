# Bug Log

Every real bug found in this project: symptom, root cause, how it was caught,
and the fix. Newest entries at the top.

Status legend: **OPEN** (not yet fixed) / **FIXED** (fix merged).

---

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

## B006 — Memories synthesize to flip-flops instead of block RAM — OPEN

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

## B005 — Design fails timing on the ripple-divided clock — OPEN

- **Symptom:** Setup slack −13.05 ns on the `div[25]` clock domain, −2.36 ns
  on CLOCK_50 (sta.summary, 2025-12-01). Works on the board only because the
  demo clock is ~0.75 Hz.
- **Root cause:** CPU is clocked by bit 25 of a free-running counter register
  (a "ripple" clock) rather than a PLL output; no meaningful timing
  constraints (.sdc) exist.
- **How caught:** Reading the STA summary during exploration (2026-07-02).
- **Fix:** Use a PLL for the CPU clock + write a real .sdc. Prerequisite for
  any honest Fmax/IPC numbers. Deferred until after the Verilator baseline.

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
