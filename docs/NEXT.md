# Next tasks — start here

Last updated 2026-07-14. `main` = the MNIST-demo board top with the
banked-M9K gshare (D024) and banked-M9K PRF (D025). The active stacked feature
branch adds the fully verified D026 LQ timing tree + B015 fix; the freshly
reassembled `synth/output_files/rv32i_cpu.sof` matches D026, not yet `main`.
Everything below is the measured backlog, most-ready first.

Division of labor: the standing project rule assigns microarchitecture to
Hanna and infrastructure to Codex. On 2026-07-14 Hanna explicitly delegated
architectural decisions for the current performance/portfolio push, so Codex
may select and implement the evidence-backed option until that delegation is
revoked. Deeper evidence for the RTL levers is in
`docs/AUDIT-2026-07-11.md` §1/§6.

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

## 2. LQ violation-path timing redesign  — ✅ DONE (D026, branch `codex/lq-balanced-tree`, 2026-07-14)

Selected the cycle-exact parallel match + balanced 8→4→2→1 age tree.
INV-L1 keeps the old scan as a Verilator oracle; a new standalone golden model
passes 250,026 cycles / 218,731 probes / 55,318 matches. It also found and
fixed **B015**, a real slot1-only-load allocation hole at LQ occupancy seven.
Both full lockstep gates and reportable CoreMark pass. Quartus: **Fmax 23.51
→ 25.10 MHz (+6.8%)**, LQ absent from all top-20 paths, board **34,798 LEs
(70%)**, +20.166 ns at the current 16.67 MHz clock. Record: DECISIONS D026.

## 3. SQ forward/replay selector → balanced youngest-match tree  — [Codex, current limiter]

D026 STA promotes the next path cleanly. Every top-20 setup path is now:

`dmem M9K → load WB bypass → dependent memory AGU → SQ serial youngest-match/replay scan → IQ load wakeup`

The worst path is 39.156 ns / 41 logic levels; Fmax is 25.10 MHz. The SQ's
8-entry `m_found/m_age` loop has the same serial reduction shape just removed
from the LQ, except it selects the **youngest older** matching store and also
distinguishes full-word forwarding from partial-overlap replay.

**Decision:** do the lowest-risk cycle-exact rewrite first: parallel per-entry
age/address candidates + a fixed 8→4→2→1 maximum-age tree, preserving
lowest-index tie behavior and `q_older` semantics. Keep the old scan as a live
simulation oracle and add a standalone SQ lifecycle/forwarding model. Do not
register the query or change load latency unless post-fit evidence says the
tree is insufficient. Acceptance: both full gates, reportable CoreMark, fit +
top-20 STA, and an actual PLL /2 slow-85C sign-off before changing the board
clock.

## 4. 2-stage pipelined issue-queue scheduler  — [Hanna, big µarch, deferred by STA]

This remains the likely deeper wall-clock project: the OoO core needs about
41.4 MHz to tie the in-order core's `0.849 IPC × 50 MHz`. D019 balanced the
select tree; a true select→wakeup split changes latency/IPC and needs CoreMark,
hello, and lockstep A/B evidence. Do it after the SQ path is removed and only
if post-change STA returns to the scheduler.

## 5. JALR target adder  — [Hanna, small µarch, deferred by STA]

A dedicated rs1+imm target adder remains a clean small optimization, but JALR
is absent from the D026 top-20 paths. Keep it queued until post-SQ STA shows the
ALU/shifter/JALR cone again.

## 6. IQ payload split  — [Hanna, medium µarch]

Split the 162-bit IQ uop into a scheduling-bits array + a payload RAM
(~111 of the 162 bits are never read by scheduling logic). ~3k LEs, and it
de-risks task #4 (less state to pipeline). Evidence: audit §1.

---

## 7. Small infra / cleanups  — [Codex, do anytime]

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
  Coverage is now 99.2% (1449/1461 on D026); established seed streams unchanged.
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
- `codex/lq-balanced-tree` = D026 + B015 local branch; full sim, fit, STA,
  and assembler green; merge/push still pending.
- Feature branches `mlp-board-demo`, `gshare-m9k-pht` pushed (now folded
  into main; safe to delete locally once you're comfortable).
- Env: the old build landmines are guarded in the Makefile — `make` just
  works. If overriding, `VERILATOR_ROOT` must be the mount form
  `/ucrt64/share/verilator`.
