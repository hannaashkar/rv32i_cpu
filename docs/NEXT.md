# Next tasks — start here

Last updated 2026-07-14. `main` = the MNIST-demo board top with the
banked-M9K gshare (D024) and banked-M9K PRF (D025). The active stacked feature
branch `codex/load-wb-bypass-cut` contains the fully verified D026 LQ, D027 SQ,
D028 IQ, and D029 load-bypass timing work. It is local, not pushed or merged.
Freshness-clean PLL-/2 D029 MNIST `.sof` and `.pof` images are assembled but
**unflashed**. Everything below is the measured backlog, most-ready first.

Division of labor: the standing project rule assigns microarchitecture to
Hanna and infrastructure to Codex. On 2026-07-14 Hanna explicitly delegated
architectural decisions for the current performance/portfolio push, so Codex
may select and implement the evidence-backed option until that delegation is
revoked. Deeper evidence for the RTL levers is in
`docs/AUDIT-2026-07-11.md` §1/§6.

---

## 0. Flash the MNIST demo  — [Hanna, hardware]  ← the milestone

The fresh D029 `.sof` is built (`synth/output_files/rv32i_cpu.sof`). This is the only
thing between the last fully signed-off image and the demo video. **Deferred
by Hanna's choice 2026-07-12 — do NOT auto-do; it needs the physical board.**

- Plug in the USB-Blaster, open Quartus Programmer, load the `.sof`, flash.
- Flip SW[2:0] to select a digit; HEX displays show true label vs the
  network's answer. Record the **on-board MNIST demo video**.
- Optional: program the `.pof` for standalone power-on boot (no PC).
- This is the first **25 MHz** OoO image. Sim, multi-corner STA, and assembly
  are clean, but the clock increase and MNIST image remain hardware claims
  only after this flash. The steady LED walker (`make mif MIF_PROG=demo`,
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

## 5. D029 load-result WB bypass cut  — ✅ DONE (branch `codex/load-wb-bypass-cut`, 2026-07-14)

D028's complete top-20 family crossed the dmem M9K read, the generic WB2
load-result EX bypass, JALR/redirect logic, and the PHT address. D029 removes
**only** the WB2 arm after proving that a successful load writes the folded
PRF direct/shadow path before any dependent uop can reach EX. WB0/WB1 ALU
bypasses remain unchanged. A permanent exact source-use oracle models the
old priority: across the full gate and reportable CoreMark it records **zero
WB2 hits**, while all six select-port/source bins are exercised.

The new `load_wb_bypass.S` has 24 checks covering RAM-load dependencies into
JALR, all six branch conditions and outcomes, both ALU inputs/ports, and store
address/data. Both cores pass **21/21 directed+C, 40/40 rv32ui, 25/25
base/system/NPU random, and 84/84 X/reset**; OoO additionally passes all queue
unit models and 25/25 violation stress. `hello.c` is cycle-exact at
**2013 cycles / 1882 instret**. Reportable CoreMark is also exact at
**1.422552 CoreMark/MHz, IPC 1.026, 506,197,207 cycles, and 519,453,600
instret**, with official CRCs and zero divergence. Coverage rises to **99.3%
(1596/1607)** across 61 programs/core.

Actual PLL-/2 fit/STA closes at **25 MHz**: **34,945 LEs (70%)**, restricted
Fmax **31.29 MHz**, slow-85C setup **+8.045 ns**, hold **+0.339 ns**, every
timing class positive, and zero unconstrained paths. Fresh `.sof`/`.pof`
images are assembled. This is a verified **50% board-clock increase** over
PLL /3, but remains unflashed; physical truth is still the earlier 16.67 MHz
OoO LED-walker/CFM image. Full record: `docs/WB_BYPASS_TIMING.md` and D029.

The new top-20 family is `rob_head` into IQ readiness/operand selection
(worst 31.517 ns). Any next frequency push must target that measured cone;
do not revive the removed dmem-bypass hypothesis.

## 6. IQ payload/timing follow-up  — [Codex + Hanna, next measured limiter]

First characterize the new `rob_head → IQ readiness` family and choose the
smallest cycle-safe cut. A true registered scheduler remains an option, but
its latency/IPC cost must be measured. Separately, split the 162-bit IQ uop
into a scheduling-bits array + a payload RAM (~111 of the 162 bits are never
read by scheduling logic). The split is worth roughly 3k LEs and de-risks a
deeper scheduler. Evidence: audit §1 and D029 STA.

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
  `sys_nops.S` + additive `--sys` random lane; both cores 21/21 directed
  and 25/25 system-random, 1,148 injected words/core, zero divergence.
  Coverage is now 99.3% (1596/1607 on D029), with the load-bypass oracle and
  new directed test included;
  established seed streams are unchanged.
- **NPU-region random mode — DONE 2026-07-14.** Additive `--npu` bursts
  exercise back-to-back GO, staging/readback ordering, busy-time immediate
  address/data dependencies, STATUS/ID/unmapped reads. Both cores 25/25;
  282 bursts / 564 GO commands per core, lockstep-clean; old streams unchanged.
- **X-state randomization lane — DONE 2026-07-14.** Separate
  `--x-assign/--x-initial unique` models + four explicit randomized-reset
  seeds; full directed+C suite 84/84 on each core, lockstep-clean. It is now
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
- `codex/load-wb-bypass-cut` = D029 stacked on D028; exact source-use oracle,
  new directed regression, all unit/system/benchmark/coverage gates, actual
  PLL-/2 fit/STA, and fresh 25 MHz `.sof`/`.pof` are green. Local only: not
  pushed or merged; images unflashed and not hardware-confirmed.
- Feature branches `mlp-board-demo`, `gshare-m9k-pht` pushed (now folded
  into main; safe to delete locally once you're comfortable).
- Env: the old build landmines are guarded in the Makefile — `make` just
  works. If overriding, `VERILATOR_ROOT` must be the mount form
  `/ucrt64/share/verilator`.
