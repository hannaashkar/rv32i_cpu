# Next tasks — start here

Last updated 2026-07-14. `main` = the MNIST-demo board top with the
banked-M9K gshare (D024) and banked-M9K PRF (D025); both cores verified
green. `synth/output_files/rv32i_cpu.sof` was reassembled successfully on
2026-07-14 and matches D025/current `main`. Everything below is the agreed
backlog, most-ready first.

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

## 1. PRF → M9K (LVT)  — ✅ DONE (D025, branch `prf-m9k-lvt`, 2026-07-12)

The audit's *other* LE pig: `ooo_prf` = 10,947 LCs (6R/3W 64×32 async-read
register file, duplicated per read port — same disease D024 cured for the
PHT). **Delivered: 18 M9K banks (LaForest LVT) + folded read + direct/shadow
write-first bypass.** Options sheet = `docs/PRF_SHRINK.md` (Hanna AFK,
delegated → Option A). **Board top 43,609 → 34,714 LEs (88% → 70%,
−8,895); M9K 95/182; fit 0 errors, timing MET +17.47 ns; IPC-neutral**
(CoreMark cycle-identical to baseline, hello.c 2013/1882; prf-tb 300k random
+ OoO 19/19+40/40+25/25+25/25-vio lockstep-clean; 5-lens adversarial review
0 defects). Record: DECISIONS.md D025. **Merged to `main` and pushed as
`ab79b50`** (the estimate was ~9–10k LEs; delivered −8,895, on the nose).

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
- **System/decode-tail coverage — DONE 2026-07-14.** Directed
  `sys_nops.S` + additive `--sys` random lane; both cores 20/20 directed
  and 25/25 system-random, 1,148 injected words/core, zero divergence.
  Coverage is now 99.2% (1428/1440); established seed streams unchanged.
- **NPU-region random mode — DONE 2026-07-14.** Additive `--npu` bursts
  exercise back-to-back GO, staging/readback ordering, busy-time immediate
  address/data dependencies, STATUS/ID/unmapped reads. Both cores 25/25;
  282 bursts / 564 GO commands per core, lockstep-clean; old streams unchanged.
- **X-state randomization lane — DONE 2026-07-14.** Separate
  `--x-assign/--x-initial unique` models + four explicit randomized-reset
  seeds; full directed+C suite 80/80 on each core, lockstep-clean. It is now
  part of both merge gates without perturbing deterministic benchmark builds.
- **INV-G2 negative self-test** — confirm the new gshare data-path shadow
  actually fires (deliberately flip the crossbar, expect $fatal, revert);
  proves it isn't vacuous.

---

## Branch / merge state (2026-07-14)

- `main` = `ab79b50` = D024 + D025 merged and pushed.
- Feature branches `mlp-board-demo`, `gshare-m9k-pht` pushed (now folded
  into main; safe to delete locally once you're comfortable).
- Env: the old build landmines are guarded in the Makefile — `make` just
  works. If overriding, `VERILATOR_ROOT` must be the mount form
  `/ucrt64/share/verilator`.
