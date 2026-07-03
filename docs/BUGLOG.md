# Bug Log

Every real bug found in this project: symptom, root cause, how it was caught,
and the fix. Newest entries at the top.

Status legend: **OPEN** (not yet fixed) / **FIXED** (fix merged).

---

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

## B004 — ADDI with imm[11:5] = 0100000 executes as SUB — OPEN

- **Symptom:** `addi rd, rs1, imm` for imm in 1024–1055 subtracts instead of
  adds.
- **Root cause:** The Dec-10 fix for B003 routes I-type ALU ops through
  `ALUOp=2'b10`, where `alu_control` checks `funct7 == 0100000` to detect
  SUB. For I-type instructions instr[31:25] is *immediate bits*, not funct7,
  so certain immediates spoof the SUB encoding. `alu_control` needs an
  "is I-type" input (or funct7 masking) so SUB detection only applies to
  R-type (and later, SRAI's shamt[10] special case).
- **How caught:** Code review of `control.v` + `alu_control.v` during repo
  verification (2026-07-03). Not yet reproduced in simulation — no test
  infrastructure existed.
- **Fix:** Planned as part of RV32I completion.

## B003 — ANDI/ORI/XORI/SLTI executed as ADD — FIXED (2025-12-10, by Hanna)

- **Symptom:** All I-type ALU instructions except ADDI computed `rs1 + imm`.
- **Root cause:** `control.v` set `ALUOp=2'b00` (forced ADD) for opcode
  0010011 instead of decoding via funct3.
- **How caught:** Present in the 2025-12-01 local snapshot; fixed in the
  version uploaded to GitHub on 2025-12-10 (`ALUOp=2'b10` for I-type).
- **Fix:** Merged in commit `0815273` ("Update control.v"). Note: the fix
  introduced B004.

## B002 — Demo program never reaches the LED MMIO address — OPEN

- **Symptom:** The hardcoded imem program comments claim
  `slli x2, x2, 28 → x2 = 0x40000000`, but the ALU has no shifter — SLLI
  (funct3=001) falls into `alu_control`'s default ADD, so x2 = 4 + 28 = 32.
  The `sw` then writes RAM address 0x20, not the LED register.
- **Root cause:** Shift instructions are not implemented anywhere in the ALU
  path; the demo program assumed they were.
- **How caught:** Instruction-by-instruction trace of `imem.v` against
  `alu_control.v` during exploration (2026-07-02).
- **Fix:** Shifts arrive with RV32I completion; the hardcoded imem is being
  replaced by `$readmemh` program loading in the Verilator bring-up anyway.

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

- **BNE decodes as BEQ:** branch-taken condition is `Branch && alu_zero`
  regardless of funct3. Not counted as a bug yet because only BEQ is claimed
  as supported; becomes a bug the moment BNE is used. Fix with RV32I
  completion.
- **dmem indexes with full `addr[31:2]`** into a 256-entry array, relying on
  implicit index truncation. Works, but masks address-decode mistakes;
  tighten during memory rework.
