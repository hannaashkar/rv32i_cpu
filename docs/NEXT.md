# Next tasks — start here

Last updated 2026-07-14. `main` = the MNIST-demo board top with the
banked-M9K gshare (D024) and banked-M9K PRF (D025). The active stacked feature
branch `codex/iq-select-pipeline` contains the fully verified D026 LQ and D027
SQ timing trees plus the fully signed-off D028 IQ top-two tournament. It is
local, not pushed or merged. Freshness-clean PLL-/3 D028 MNIST `.sof` and
`.pof` images are assembled but **unflashed**. Everything below is the measured
backlog, most-ready first.

Division of labor: the standing project rule assigns microarchitecture to
Hanna and infrastructure to Codex. On 2026-07-14 Hanna explicitly delegated
architectural decisions for the current performance/portfolio push, so Codex
may select and implement the evidence-backed option until that delegation is
revoked. Deeper evidence for the RTL levers is in
`docs/AUDIT-2026-07-11.md` §1/§6.

---

## 0. Flash the MNIST demo  — [Hanna, hardware]  ← the milestone

The fresh D028 `.sof` is built (`synth/output_files/rv32i_cpu.sof`). This is the only
thing between the last fully signed-off image and the demo video. **Deferred
by Hanna's choice 2026-07-12 — do NOT auto-do; it needs the physical board.**

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

## 2. LQ violation-path timing redesign  — ✅ DONE (D026, branch `codex/lq-balanced-tree`, 2026-07-14)

Selected the cycle-exact parallel match + balanced 8→4→2→1 age tree.
INV-L1 keeps the old scan as a Verilator oracle; a new standalone golden model
passes 250,026 cycles / 218,731 probes / 55,318 matches. It also found and
fixed **B015**, a real slot1-only-load allocation hole at LQ occupancy seven.
Both full lockstep gates and reportable CoreMark pass. Quartus: **Fmax 23.51
→ 25.10 MHz (+6.8%)**, LQ absent from all top-20 paths, board **34,798 LEs
(70%)**, +20.166 ns at the current 16.67 MHz clock. Record: DECISIONS D026.

## 3. SQ forward/replay selector → balanced youngest-match tree  — ✅ DONE (D027, branch `codex/sq-forward-tree`, 2026-07-14)

The 8-entry serial `m_found/m_age` reduction is now a cycle-exact parallel
candidate stage plus fixed 8→4→2→1 maximum-age tree. The old scan remains a
live Verilator oracle. The independent `sq-tb` golden model passes **300,087
cycles / 300,088 queries / 45,313 forwards / 90,252 conflicts / 36,668 drains
/ 2,382 flushes**, with mandatory coverage of occupancy 0–8, one/two/final-slot
allocation, SB/SH/SW, multi-match selection, backpressure, flush/wrap, and
winner leaves 0–7. INV-S1/S2/S3 cover scan equivalence plus SQ identity,
occupancy, ordering, fill/retire/flush, and query-window invariants.

The result is cycle-identical on official reportable CoreMark: **1.422552
CoreMark/MHz, IPC 1.026, 506,197,207 cycles, 519,453,600 lockstep comparisons**.
Both cores pass 20/20 directed+C, 40/40 rv32ui, 25/25 base/system/NPU random,
and 80/80 X-state runs; OoO also passes 25/25 violation stress. Quartus fits at
**34,787 LEs (70%), 95 M9Ks, Fmax 25.47 MHz**, with +20.745 ns PLL-/3 setup,
+0.337 ns worst hold, every timing check positive, and zero unconstrained
paths. SQ itself is 924 combinational / 596 registers at map and 1,024 LCs /
596 registers after fit; no serial SQ node appears in the top 20.

## 4. IQ port-1 top-two tournament  — ✅ DONE (D028, branch `codex/iq-select-pipeline`, 2026-07-14)

D027's complete top-20 family came from the dependent port-1
`pick → clear → repick` chain inside `rob_head → IQ r1`. D028 replaces it with
one balanced sorted-pair tree that returns the two oldest ALU candidates
together. It adds no state or latency; INV-I1 keeps the old topology live as
an every-cycle oracle. `iq-tb` passes **300,553 cycles**, including 300,000
random cycles, 74,571 complete 162-bit payload checks, and all 3×16 winner
leaves. `hello.c` remains **2013 cycles / 1882 instret**.

Routed evidence is complete: **35,096 LEs (71%)**, Fmax **27.02 MHz**, and
+22.994 ns setup at PLL /3. The IQ is absent from all top-20 paths. Both cores
pass 20/20 directed+C, 40/40 rv32ui, 25/25 base/system/NPU random, and 80/80
X/reset; OoO additionally passes LQ/SQ/IQ units and 25/25 violation stress,
all lockstep-clean. Fresh coverage is **99.2% (1522/1534)** over 60 programs
per core, zero failures, with every D028 IQ addition covered and the same 12
documented lines uncovered. Reportable 720-iteration CoreMark is cycle-exact
to D027: **1.422552 CoreMark/MHz, IPC 1.026, 506,197,207 full-run cycles,
519,453,600 lockstep comparisons**, official CRCs and validation, zero
divergence. D028's merge gate is complete. See `docs/IQ_TIMING.md` and
DECISIONS D028.

The board stays at PLL /3. D028 would leave a theoretical **+2.994 ns** at
25 MHz, narrowly below the predeclared ≥3 ns slow-85C gate; no /2 claim was
made. A final post-RTL map+fit rerun reproduced the documented results, and
assembly completed at 22:44:32 with 0 errors / 0 warnings from MIF stamp `mlp`.
The fresh D028 MNIST `.sof`/`.pof` are freshness-clean but unflashed, so no new
hardware result is claimed.

## 5. D029 load/JALR/redirect/PHT timing path  — [Codex, next measured limiter]

All D028 top-20 paths now run from the dmem M9K read through load/JALR/redirect
logic to a gshare PHT M9K address (**36.433–36.132 ns**). Characterize the
shared cone, separate unavoidable M9K delay from logic/routing, then present
the smallest cycle-safe cut. A dedicated JALR target adder is again relevant,
but must be chosen from path-level evidence rather than assumed to fix the
whole family. Require full lockstep, workload IPC, fit, and multi-corner STA.

A true registered IQ scheduler is deferred because the IQ is no longer in the
top 20. Reconsider it only if it returns after D029 or a higher frequency goal
requires a deeper pipeline.

## 6. IQ payload split  — [Hanna, medium µarch]

Split the 162-bit IQ uop into a scheduling-bits array + a payload RAM
(~111 of the 162 bits are never read by scheduling logic). ~3k LEs, and it
de-risks task #4 (less state to pipeline). Evidence: audit §1.

---

## 7. Small infra / cleanups  — [Codex, do anytime]

- **Regenerate the portfolio book before sharing it.** The ignored local
  `docs/book/rv32i_soc_book.{html,pdf}` still contains pre-D024/D025/D027 area,
  NPU, and lockstep numbers. Rebuild it from the tracked evidence ledger (or
  label/remove the stale copy); never send the current local PDF to recruiters.
- **Portable setup/tool discovery** — the wrapper is excellent on Hanna's
  machine, but Makefile defaults still embed local xPack/Python/Quartus paths.
  Add `docs/SETUP.md`, PATH-first discovery, explicit override examples, and a
  clean-clone smoke check without weakening the known-good Windows flow.
- **Root license — [Hanna legal choice].** The public repository has no root
  license. Pick an intentional hardware/software license (and confirm how the
  separately licensed vendored CoreMark source is described) before adding it;
  Codex should not silently choose ownership terms.
- **CI coverage for the new lanes** — add bounded system/NPU/X-state jobs after
  this verification branch lands; preserve seeded artifacts on failure.
- **NPU on-board error patterns** — mlp_board.c parks with dark displays
  on NPU-ID / self-test failure (indistinguishable from a dead board);
  drive an "E-1"/"E-2" + fail-count pattern on HEX first. (Hanna-gated:
  touches board SW behavior, but tiny.)
- **Parallel test suites** (`make -j`) — regress/isa/rand run serially in
  shell loops; ~4–6× wall-clock win via per-test stamp targets.
- **System/decode-tail coverage — DONE 2026-07-14.** Directed
  `sys_nops.S` + additive `--sys` random lane; both cores 20/20 directed
  and 25/25 system-random, 1,148 injected words/core, zero divergence.
  Coverage is now 99.2% (1522/1534 on D028), with every new IQ line covered;
  established seed streams are unchanged.
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
- `codex/verif-hardening` = verification/evidence batch commits `533aaa4` +
  `15f6d98` (local, not pushed).
- `codex/lq-balanced-tree` = D026 + B015 committed locally; full sim, fit, STA,
  and assembler green.
- `codex/sq-forward-tree` = D027 stacked on D026; full sim, reportable
  CoreMark, coverage, fit, STA, `.sof`, and `.pof` green. Local only: not
  pushed or merged.
- `codex/iq-select-pipeline` = D028 stacked on D027; all unit/system lockstep
  gates, fresh coverage, hello.c, reportable CoreMark, fit, and STA green.
  Fresh D028 MNIST `.sof`/`.pof` assembled and freshness-clean. Local only: not
  merged or pushed; images unflashed and not hardware-confirmed.
- Feature branches `mlp-board-demo`, `gshare-m9k-pht` pushed (now folded
  into main; safe to delete locally once you're comfortable).
- Env: the old build landmines are guarded in the Makefile — `make` just
  works. If overriding, `VERILATOR_ROOT` must be the mount form
  `/ucrt64/share/verilator`.
