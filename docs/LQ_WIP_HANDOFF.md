# LQ (speculative loads) — handoff (NOW COMPLETE)

**Status: ✅ DONE (2026-07-08).** The `ld_st` bug was root-caused and fixed;
full suite is green and speculation is measured. See **DECISIONS.md D020** and
**BUGLOG B013** for the authoritative record — the rest of this file is kept as
the historical debugging trail.

> **Resolution (superseding the "one bug left" analysis below):** the remaining
> failure was NOT the pre-flush wrong-path-branch race hypothesized here. The
> real cause (**B013**) was that the load-violation flush-at-head never cleared
> the issue queue: it reused the branch path with `flush_tag = head_tag − 1`,
> but the 6-bit relage predicate makes `relage > 63` always false, so ZERO IQ
> entries were cleared. Surviving pre-flush IQ entries re-issued post-flush with
> reallocated phys regs. Fix: a dedicated `flush_all` port on `ooo_iq` driven by
> `lq_flush_start`. Fixes A/B/C proposed below were all aimed at the wrong
> mechanism and were not needed.
>
> **Verified:** OoO 14/14 + 40/40 riscv-tests + 25/25 random + 25/25 `--vio`
> (1185 violations), all lockstep-clean; CoreMark IPC 1.026 vs 1.006
> conservative (+2.0%); Fmax 26.32 MHz slow-85C (LQ CAM not the wall). `--vio`
> mode + `make regress-rand-vio` added to close the LQ.md Inc-0 coverage gap.

---

**(historical) Status: ~95% done, ONE bug left. Branch `ooo-iq-pipeline`.**
Date paused: 2026-07-08.

## TL;DR for the next session

Speculative loads + load queue + violation-detect + poison + flush-at-head
recovery are all implemented and the **happy path is fully green** (14/14
regress + 25/25 random, lockstep-clean). The recovery works on the directed
violation test `sw/tests/lq_violation.S` (PASS). **One official riscv-test,
`ld_st`, still fails** — and I traced the root cause to a precise mechanism
(below). Fixing that + re-running the full suite is all that remains for LQ
increment 1.

## How to build & run (IMPORTANT env gotcha)

Builds SILENTLY FAIL unless `VERILATOR_ROOT` is set. The reliable recipe is in
`<scratchpad>/build_ooo.sh`:
```
export PATH="/c/Users/ASUS/tools/msys64/ucrt64/bin:/c/Users/ASUS/tools/msys64/usr/bin:$PATH"
export TMP='C:/Users/ASUS/AppData/Local/Temp'; export TEMP="$TMP"; export TMPDIR="$TMP"
export VERILATOR_ROOT='C:/Users/ASUS/tools/msys64/ucrt64/share/verilator'   # <-- REQUIRED
cd .../TechnionProject26
make sim-ooo VM_PARALLEL_BUILDS=1 >/dev/null 2>&1 || true      # verilate (parallel race OK)
make -C obj_dir_ooo -f Vooo_cpu.mk -j 1 TMP="$TMP" TEMP="$TMP" TMPDIR="$TMP" \
     OPT_FAST=-O2 OPT_SLOW=-O2 OPT_GLOBAL=-O2 VM_PARALLEL_BUILDS=1   # objects single-threaded
```
Debug build adds `+define+LQ_PROBE` to the verilate step (traces violations/flushes).

Repro the failing test:
```
obj_dir_ooo/Vooo_cpu.exe +imem=sw/riscv-tests/rv32ui/ld_st.text.hex \
                         +dmem=sw/riscv-tests/rv32ui/ld_st.data.hex
```
Fast gates: `sw/tests/lq_violation.hex` (PASSES — recovery works),
`sw/ctests/load_order.text.hex` + `.data.hex` (happy-path oracle).

## The remaining bug (ROOT CAUSE FOUND — this is the key handoff)

`ld_st` does store-then-load to the same byte address. A load speculates,
reads stale, and a younger dependent **branch (`bne a4,t2` at pc=0x44) that
depends on the load executes and resolves BEFORE the load's violation is
detected**. Trace evidence (from `+define+LQ_PROBE` plus branch/EX traces):

- The re-executed (post-flush) load@0x40 produces the CORRECT value
  (x14 = 0xffffffdd) and the re-executed branch@0x44 reads the correct phys
  reg (ps1=37) and resolves `taken=0` (correct — a4==t2).
- BUT a **second, stale copy of branch@0x44 (ps1=42, the pre-flush rename)
  also executes**, reads a=0x00000000, resolves `taken=1`, and redirects to
  the test's `fail` handler (0xe68). That stale branch is wrong-path relative
  to the poisoned load and should never have taken architectural effect.

So the bug is: **a younger, wrong-path branch that is data-dependent on the
speculative load resolves (and mis-redirects) in the window BEFORE the
violation is detected + the flush completes.** The flush-at-head correctly
squashes younger uops, but the wrong-path branch's redirect (restore_en) fires
too early / is not fully suppressed, corrupting the fetch stream so the
machine ends up on the fail path.

### Fixes already applied (working — keep these)

1. **D/R register clears on flush** (`ooo_cpu.v`, `dr_v0/dr_v1 <= 0` on
   `restore_en || lq_flush_start || lq_flushing`) — fixed a stale-dispatch
   bug; `lq_violation.S` went from MISMATCH to PASS.
2. **Single-cycle-safe freelist rebuild** via a per-cycle sweep FSM
   (`lq_state`/`lq_sweep`/`lq_wp`) — the earlier nested-function unroll
   crashed Verilator elaboration; the earlier off-by-one livelocked. Now
   sweeps phys 1..63, pushes non-`in_arat` tags, `SWEEP_DONE wp=32` verified,
   no architectural-reg leak verified.
3. **SQ drains before flush** — `lq_flush_start` gated on `!mw_valid` so the
   re-executed load reads correct dmem (does not depend on post-flush SQ
   forward color math). Does NOT deadlock (younger uncommitted stores never
   set mw_valid).
4. **`p0_mispredict` gated by `!lq_flush_start && !lq_flushing`** — a branch
   being squashed by the flush must not fire its own recovery. (Necessary but
   NOT sufficient — see below.)

### What to try next (the actual remaining fix)

The stale branch resolves BEFORE the flush window, so gating `p0_mispredict`
on `lq_flushing` doesn't catch it. Candidate fixes to evaluate:

- **(A) Poison-aware branch suppression:** when a load is poisoned (violation
  detected), the branch that already mis-redirected is younger than the load;
  its `restore_en` already fired and moved `pcF`. The subsequent flush-at-head
  MUST re-assert the correct `pcF = load.pc` and win over any in-flight
  redirect. Verify the flush's `pcF <= rob_pc[h0]` truly overrides and that no
  younger-branch checkpoint state survives to re-redirect. Likely the cleanest
  fix: ensure the poisoned load's flush is not blocked/delayed by an
  intervening branch restore (the two recoveries must compose — a branch
  restore older than the poisoned load is fine; younger must be discarded by
  the flush).
- **(B) Detect the violation earlier / mark the load's dependents:** on a
  violation, in addition to poisoning the load, ensure everything younger
  (incl. the already-resolved branch) is squashed at the flush — check whether
  the branch's mispredict-redirect corrupted GHR/BTB/RAS or the checkpoint
  ring in a way the flush doesn't repair (the flush resets chk_a/chk_f but
  does NOT restore GHR/RAS — may be the leak; a wrong-path branch trained the
  predictor).
- **(C) Simplest robust option:** make a poisoned load's flush ALSO restore
  GHR/RAS to a safe state and invalidate any younger branch checkpoint, so no
  stale predictor/redirect state survives. GHR/RAS only affect prediction
  (not correctness) EXCEPT that a wrong redirect changes which instructions
  fetch — so this may matter.

**Recommended first step next session:** add a cycle-stamped trace of
`restore_en`, `restore_npc`, `pcF`, `lq_flush_start`, and the branch@0x44 EX,
to see the EXACT cycle ordering of (stale branch mispredict redirect) vs
(violation detect) vs (flush). That ordering picks between fixes A/B/C.

## Files changed on this branch (all uncommitted WIP will be committed as "WIP")

- `rtl/ooo/ooo_lq.v` (NEW) — 8-entry load queue + violation CAM.
- `rtl/ooo/ooo_pkg.vh` — LQD/LQW params.
- `rtl/ooo/ooo_iq.v` — `SPEC_LOADS` param (default 1) relaxing the load gate.
- `rtl/ooo/ooo_sq.v` — `commit_tail4` + `sq_empty` outputs for the flush.
- `rtl/ooo/ooo_cpu.v` — aRAT, rob_poison/rob_ld, violation→poison, flush-at-
  head FSM, dispatch/frontend/mispredict gating, LQ instantiation, LQ_PROBE.
- `docs/LQ.md` — design spec (Strategy B-real, corrected).
- `sw/tests/lq_violation.S` (NEW) — directed violation test (PASSES).
- `sw/ctests/load_order.c` (committed already) — happy-path oracle.

## Task 1 (DONE, separate, safe): IQ pipelining

Already committed on this branch (commits e51b1b1, 26d8e8b, 847dc31):
balanced-tree IQ select + parallel port-1 → **Fmax 8.42→19.65 MHz (2.33x),
IPC-identical, board re-clocked to 16.67 MHz**, D019 logged. This is
independent of the LQ and is fully verified — could be split to its own branch
and merged even if the LQ isn't finished.

## Task 3 (NOT started): imem block-RAM + on-board MLP demo

Plan: split imem into even/odd single-port banks (pc0 and pc1=pc0+4 always
differ in bit 2, so one bank serves each) → both M9K-inferrable and
ROM-initializable via `ram_init_file`, sidestepping the dual-read-port MIF
limit on MAX 10. Then wire the MLP program image + run `make npu-mlp-ooo` on
the board.
