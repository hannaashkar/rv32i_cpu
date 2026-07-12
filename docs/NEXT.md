# Next tasks — start here

Last updated 2026-07-12. `main` = the MNIST-demo board top with the
banked-M9K gshare (D024); both cores verified green; `.sof` built and
ready to flash. Everything below is the agreed backlog, most-ready first.

Division of labor (project rule): **Hanna owns microarchitecture
decisions** — for those, Claude presents 2–3 options with tradeoffs and
waits. **Claude owns infrastructure** (Makefiles, TB, scripts, docs) and
can just do it. Owner tagged per task. Deeper evidence for the RTL levers
is in `docs/AUDIT-2026-07-11.md` §1/§6 and `docs/GSHARE_SHRINK.md`.

---

## 0. Flash the MNIST demo  — [Hanna, hardware]  ← the milestone

The `.sof` is built (`synth/output_files/rv32i_cpu.sof`). This is the only
thing between here and the demo video. **Deferred by Hanna's choice
2026-07-12 — do NOT auto-do; it needs the physical board.**

- Plug in the USB-Blaster, open Quartus Programmer, load the `.sof`, flash.
- Flip SW[2:0] to select a digit; HEX displays show true label vs the
  network's answer. Record the **on-board MNIST demo video**.
- Optional: program the `.pof` for standalone power-on boot (no PC).
- Watch-item: first bitstream with the banked-M9K PHT on silicon. Sim +
  STA are clean, so it should just work; if the demo misbehaves, suspect
  the PHT banking first. The steady LED walker (`make mif MIF_PROG=demo`,
  recompile) is the fallback bring-up sanity check.

---

## 1. PRF → M9K (LVT)  — [Hanna decides, then Claude implements]

The audit's *other* LE pig: `ooo_prf` = 10,947 LCs (6R/3W 64×32 async-read
register file, duplicated per read port — same disease D024 just cured for
the PHT). Frees an estimated ~9–10k LEs; M9K usage is only 36%, so there
is room. Same latch-fold argument as D016/D022/D024 (read addresses are
already registered), so it should stay IPC-neutral and lockstep-verifiable.

- **What Claude will bring first:** an options sheet like
  `docs/GSHARE_SHRINK.md` — LVT (live-value-table) replication vs.
  banked-by-read-port vs. status quo, with LE/timing/complexity tradeoffs.
- Highest-value remaining area lever; do this before the scheduler if the
  goal is maximum free fabric.

## 2. 2-stage pipelined issue-queue scheduler  — [Hanna, big µarch]

The real fix for OoO **wall-clock** speed. Today perf = IPC × Fmax, and
OoO's Fmax (~23 MHz on the board) is the limiter — it needs ~42 MHz to
beat the in-order core's 50 MHz despite winning on IPC. The fabric now has
room (88%) to pipeline the select+wakeup. D019 pipelined the *select*
tree; this is the deferred *2-stage* select→wakeup split. Changes IPC —
must A/B CoreMark/hello and lockstep-verify. Biggest project on the list.

## 3. JALR target adder  — [Hanna, small µarch]

The current critical path is `dmem-load → rob_poison` (the D020 LQ CAM),
and JALR's target compare rides the full ALU/shifter cone. A dedicated
rs1+imm target adder cuts ~10 ns off that cone. Small RTL change,
lockstep-verifiable; do it when chasing the next clock bump (PLL /3 → a
faster fractional ratio, 20–25 MHz).

## 4. IQ payload split  — [Hanna, medium µarch]

Split the 162-bit IQ uop into a scheduling-bits array + a payload RAM
(~111 of the 162 bits are never read by scheduling logic). ~3k LEs, and it
de-risks task #2 (less state to pipeline). Evidence: audit §1.

---

## 5. Small infra / cleanups  — [Claude, do anytime]

- **NPU on-board error patterns** — mlp_board.c parks with dark displays
  on NPU-ID / self-test failure (indistinguishable from a dead board);
  drive an "E-1"/"E-2" + fail-count pattern on HEX first. (Hanna-gated:
  touches board SW behavior, but tiny.)
- **Parallel test suites** (`make -j`) — regress/isa/rand run serially in
  shell loops; ~4–6× wall-clock win via per-test stamp targets.
- **FENCE / ECALL / EBREAK + NPU-region random modes** — the 1% RTL
  coverage tail (99.0% now) is exactly these never-executed decode paths;
  add them to `gen_random_test.py` (ISS already NOPs them → lockstep
  checks for free) + a directed `sys_nops.S`.
- **X-state randomization lane** — `--x-assign unique` build variant to
  catch missing-reset bugs lockstep can't see (both arms zero-init today).
- **INV-G2 negative self-test** — confirm the new gshare data-path shadow
  actually fires (deliberately flip the crossbar, expect $fatal, revert);
  proves it isn't vacuous.

---

## Branch / merge state (2026-07-12)

- `main` = `e2a54b7` = everything above's prerequisites merged + pushed.
- Feature branches `mlp-board-demo`, `gshare-m9k-pht` pushed (now folded
  into main; safe to delete locally once you're comfortable).
- Env: the old build landmines are guarded in the Makefile — `make` just
  works. If overriding, `VERILATOR_ROOT` must be the mount form
  `/ucrt64/share/verilator`.
