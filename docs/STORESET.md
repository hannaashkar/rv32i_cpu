# Store-set memory-dependence predictor — design spec (D021)

Status: **IMPLEMENTED** (2026-07-09, branch `ooo-store-set`). Fixes the D020
open call: speculative loads win on violation-sparse code (CoreMark +2.0%)
but lose on violation-dense code (hello.c −36%, 15 stack-spill violations ×
the ~46-cycle flush-at-head drain — 2613 − 1921 = 692 ≈ 15 × 46, the drains
explain the ENTIRE gap). The predictor stops re-speculating a load once it
has violated: **hello.c 2613 → 1989 cycles (violations 15 → 1)** while
keeping full speculation everywhere the tables are cold. Reference:
G. Chrysos & J. Emer, *Memory Dependence Prediction using Store Sets*,
ISCA 1998 (the Alpha 21464-lineage mechanism); the 1-bit comparison policy
is the Alpha 21264 `stWait` table (R. Kessler, IEEE Micro 1999).

## The one-sentence idea

The IQ already holds, per entry, an 8-bit "wait until these SQ slots have
known addresses" mask that decays with `sq_unknown` — so the whole predictor
reduces to a **dispatch-time mask policy**: the top chooses each mem-op's
mask, and the predictor's job is to name *one* SQ slot (the predicted
producer store) instead of "all older unknown stores" (conservative) or
"none" (speculative).

## Policies (`LOAD_POLICY` parameter on ooo_cpu, Verilator `-GLOAD_POLICY=n`)

| n | load mask | store mask | = |
|---|---|---|---|
| 0 | `mask_full` | 0 | conservative (D020 `SPEC_LOADS=0`), cycle-identical |
| 1 | 0 | 0 | always-speculate (D020 `SPEC_LOADS=1`), cycle-identical |
| **2** | pred ? `onehot(LFST) & mask_full` : 0 | same | **store sets** (default) |
| 3 | trained ? `mask_full` : 0 | 0 | 21264-style 1-bit load-wait (measured comparison) |

`mask_full` = `mask0` (slot0) / `mask1` (slot1 — includes the same-cycle
slot0-store bit). The IQ gate is uniform: `elig_mem = ready && is_mem &&
(mask==0)`; `SPEC_LOADS` is gone from `ooo_iq`, which has no policy
knowledge at all. Policies constant-fold per build; 0/1 produce exactly the
D020 netlists (verified cycle-identical: hello.c 1921 / 2613).

## Structures (`rtl/ooo/ooo_stset.v`)

- **SSIT** 64 × {v, ssid[3:0]}, direct-mapped on `pc[7:2]`, untagged
  (aliasing = a spurious set merge = bounded extra waits, never
  incorrectness). Parameter `SSIT_AW` (64→32 is the LE escape).
- **LFST** 16 × {v, sqpos[2:0]} = the SQ slot of the **last dispatched**
  store of the set. Deviation from the paper (which stores an instruction
  number), and deliberately so: naming the SQ slot lets `sq_unknown`
  implement both the wait AND the paper's invalidate-at-store-execute for
  free (an executed store's unknown bit is already 0).
- **Decay**: all valid bits + the ssid allocator clear every 2^16 cycles
  (`DECAY_W`) — cyclic clearing, an order above the 21264's epoch because
  our misprediction repair costs a ~46-cycle drain, not a replay trap.

## Dataflow

- **Lookup (R stage, combinational)**: both dispatch slots read SSIT on
  `dr_pc*[7:2]`; a valid ssid reads LFST; hit → `pred* = onehot(sqpos)`.
  The chain is FF-to-FF (D/R regs → IQ mask flops) and touches neither the
  rename/ok cone nor the IQ wakeup path.
- **Store dispatch**: a dispatching store with a valid ssid writes
  LFST[ssid] = its own SQ slot (slot1/younger wins same-cycle collisions).
  **Slot1 bypass**: slot0's same-cycle LFST write is forwarded to slot1's
  lookup, so a co-dispatched `sw`/`lw` pair (the hello.c stack-spill shape)
  predicts correctly the very cycle it dispatches together.
- **In-set store→store ordering**: predicted STORES wait too (same mask
  mechanism). This makes "wait for the last fetched store of the set"
  transitive — without it, two same-set in-flight stores (older slow,
  younger fast) livelock a load into re-violating against the older one
  every iteration (`sw/tests/stset_pair.S` part B exercises exactly this).
- **Training (2-phase)**: cycle N registers {`rob_pc` tag of the violated
  load, `ex_u[2]` store PC} gated exactly like the poison write (wrong-path
  violations under a same-cycle branch restore never train). Cycle N+1
  reads `rob_pc[tag]` and applies the paper's merge rules — fresh ssid from
  a wrapping allocator / one-sided join / both-valid → min(ssid), no
  full-table remap (the paper's declared-winner rule; losers migrate lazily
  at one violation each). The apply cycle borrows the module's own two SSIT
  read ports (`train_busy` internally blanks that cycle's predictions — a
  free hint blackout inside the flush drain), so training adds ZERO logic
  after the LQ violation CAM (the D020 critical path) and no extra read
  muxes.

## Why it is safe (the bracket argument)

**INV-P1 (subset)**: every dispatched mask is ANDed with the conservative
`mask_full`, so each mem-op's wait lies between the two *already verified*
D020 extremes — more waiting than policy 1 is repaired by nothing (waiting
is always safe; that is policy 0's correctness argument), less waiting than
policy 0 is repaired by the LQ violation CAM + flush-at-head (policy 1's
argument). Predictor state is a pure hint: never checkpointed, never
restored, invisible to the ISS/lockstep.

**Deadlock-freedom**: a surviving mask bit always denotes the same
still-valid, still-unknown store that occupied the slot at dispatch (the SQ
holds `v=0` outside `[head,tail)` and there is a guaranteed ≥1-cycle dead
window before any slot reuse, so a bit either decays at or before the
reallocation edge). Wait chains therefore point strictly older and
terminate. LFST staleness self-heals through the AND: a drained producer
means every older same-set store also drained (SQ drains in order) — the
load reading memory is then *correct*, not a misprediction.

Invariants INV-P1..P10 are enforced in sim: subset / one-hot / no-self-wait
asserts at dispatch (`ooo_cpu.v`), the mask⊆live-unknown-slots check
(`ooo_iq.v`, via the `unknown_raw` debug port — the assertion that guards
the deadlock proof directly), training-reads-live-ROB-entry, and a ROB-head
forward-progress watchdog (>2048 cycles stalled = $fatal) that converts any
residual wedge into an immediate sim failure.

## Verification

- **Unit TB** (`make stset-tb`): `tb/verilator/stset_tb.cpp` vs a C++
  golden model — directed merge/bypass/decay/alias cases + 200k random
  interleavings with every output checked every cycle (DECAY_W=8 → ~780
  decay epochs covered). PASS, 0 failures.
- **New directed suites** (value-based, pass under every policy and on the
  in-order core): `stset_predict.S` (same-PC violate-then-retrain loop —
  violations drop 6 → 1), `stset_pair.S` (co-dispatched pair bypass +
  in-set store chain + stale-LFST self-heal after a branch-skipped store),
  `stset_precise.S` (precision microbench: after training, policy 2 waits
  only on the true producer while policy 3 also waits on an unrelated
  slow-address store — the paper's Figure-1 scenario, measured).
- **Full gates** on the policy-2 default: regress-ooo 17/17 + riscv-tests
  40/40 (incl. `ld_st`) + 25/25 random + 25/25 `--vio` stress, all
  lockstep-clean; policies 0/1 spot-regressed (cycle-identical to D020);
  in-order core untouched. The `--vio` suite deliberately remains a valid
  flush-recovery stressor under the predictor: its violation sites are
  single-shot straight-line code at fresh PCs, so training can never
  suppress them (verified from `gen_random_test.py::emit_vio`).

## Measured results (D021; full table + method in DECISIONS.md)

| build | hello.c cycles | violations | CoreMark IPC |
|---|---|---|---|
| 0 conservative | 1921 | 0 | 1.006 |
| 1 speculative (D020) | 2613 | 15 | 1.026 |
| **2 store sets** | **1989** | **1** | *(D021 table)* |
| 3 21264 1-bit | *(D021 table)* | *(D021 table)* | — |

hello.c recovers **90% of the D020 regression** (2613 → 1989 vs the 1921
floor); the 68-cycle residual is one irreducible training flush + the
trained loads' short waits, and it amortizes to zero on longer programs.
`ld_st` drops 49 → 31 violations (its remaining sites are single-shot —
distinct static PCs — which no PC-indexed predictor can help; same reason
the --vio suite keeps its full coverage).

## Sizing rationale (defensible defaults, LE escapes pre-analyzed)

- SSIT 64: hello.c trains ~2-14 PCs, CoreMark ~0 — collisions among a dozen
  trained PCs at 64 entries ≈ 1 expected; 32 would roughly double that and
  is still IPC-immaterial on these workloads (the escape costs nothing to
  take). False positives (spurious wait on one store's address) cost 1-3
  cycles; false negatives cost a 46+ cycle flush — the asymmetry justifies
  untagged-and-generous.
- SSID space 16: SQ depth 8 bounds useful in-flight distinctness; 16 adds
  headroom for trained-but-idle sets between decays. LFST payload is a
  3-bit SQ slot, so >16 sets buys nothing.
- Decay 2^16: hello.c (~2k cycles) never decays mid-run; CoreMark sees
  ~6,400 epochs and a pathological once-per-epoch retrainer costs 0.07%
  worst-case. 21264 cleared ~16k-cycle epochs; we bias longer because our
  repair is a drain, not a trap.
