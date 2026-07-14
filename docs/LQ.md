# Speculative Loads + Load Queue (LQ) — design spec

Status: **IMPLEMENTED, policy-tuned, and timing-optimized** (D020/D021/D026).
See DECISIONS.md D020 for speculative-load recovery, D021 for the shipping
store-set policy, and D026 for the cycle-exact balanced violation selector.
BUGLOG B013 records the recovery-flush defect; B015 records the final-slot
slot1-only allocation defect found by D026's new standalone unit model.

D026's LQ evidence remains: `lq-tb` passed 250,026 directed+random cycles,
and the serial violation select was replaced by a fixed 8→4→2→1 minimum-age
tree with a simulation-only serial oracle. That change improved board-top
Fmax **23.51 → 25.10 MHz (+6.8%)** and removed the LQ from every top-20 path.

Current D029 system evidence on local branch `codex/load-wb-bypass-cut` (not
merged or pushed) adds the cycle-exact SQ selector, IQ top-two tournament, and
the proven-dead WB2 load-result EX-bypass cut. Both cores pass **21/21
directed+C, 40/40 rv32ui, 25/25 base, 25/25 system-tail, 25/25 NPU/MMIO, and
84/84 randomized-reset runs**; OoO additionally passes every queue/PRF unit
model and 25/25 `--vio`, all lockstep-clean. Line coverage is **99.3%
(1596/1607)** across 61 programs/core. Reportable CoreMark remains cycle-exact
at **1.422552 CoreMark/MHz, IPC 1.026, 506,197,207 cycles, and 519,453,600
retired instructions lockstep-checked**. D029's permanent exact source-use
oracle exercises all six select-port/source bins and reports zero cases where
the removed WB2 arm would have won.

The D029 board top fits at **34,945 LEs (70%)**. Actual PLL-/2 multi-corner STA
closes at **25 MHz**, with restricted Fmax **31.29 MHz**, slow-85C setup
**+8.045 ns**, hold **+0.339 ns**, every timing class positive, and zero
unconstrained paths. The former dmem/load-bypass family is absent from the top
20; the measured limiter is now `rob_head → IQ readiness/operand selection`
(worst 31.517 ns). Freshness-clean D029 MNIST `.sof`/`.pof` images are
assembled but unflashed; hardware truth remains the earlier 16.67 MHz
LED-walker/CFM image.

Historical D020 characterization remains useful: CoreMark (rare violations)
was **1.026** speculative vs **1.006** conservative IPC (+2.0%), while hello.c
(15 stack-spill violations) regressed 36% because flush-at-head recovery costs
~46 cycles. D021's store-set predictor resolved that policy call. D020's
**26.32 MHz** figure was a bare-core characterization on a different fit; it
is not the current board-top Fmax.
Owner decisions (Hanna): LQ depth = **8**; recovery = **poison + flush at ROB
head** (Strategy B). Derived from a 3-way adversarial design analysis
(structure / recovery / ISS-lockstep).

## Why

Today loads are **conservative**: a load issues only when every older store
has a known address (the IQ `mask==0` gate). A load therefore stalls behind
any un-executed older store even when they target different addresses. This
costs IPC on pointer/list/struct code. Speculative loads let a load issue
*early* (guessing no conflict) and detect/repair the rare real conflict.

## Mechanism (what changes)

1. **Relax the IQ load gate.** A load becomes eligible without waiting for all
   older store addresses. (It still consults SQ forwarding when it executes.)
2. **Load queue (LQ), 8 entries.** A load allocates an LQ entry at **dispatch**
   and frees it at **retire**.

   | field | bits | meaning |
   |-------|------|---------|
   | `v` | 1 | entry valid (allocated, not yet retired/squashed) |
   | `tag` | 6 | the load's ROB tag (age key) |
   | `executed` | 1 | the load has performed its read (address valid) |
   | `waddr` | 30 | word address `addr[31:2]` captured at execute |
   | `bytemask` | 4 | which bytes the load consumed (from funct3 + addr[1:0]) |

3. **Violation CAM.** When a store computes its address (the single port2 SQ
   `fill` at EX), CAM it against every LQ entry that is (a) valid, (b)
   `executed`, (c) **younger** than the store (`is_younger(load.tag,
   store.tag)` in modular ROB-tag arithmetic), and (d) overlaps in
   word-address AND byte-mask. A hit = a younger load already read a stale
   value = **memory-ordering violation**.

4. **Recovery = poison + flush at head (Strategy B-real).** On a CAM hit, set
   a `poison` bit on the violated load's ROB entry. Do **not** squash
   immediately. When that load reaches the ROB head, trigger a full pipeline
   flush and refetch from the load's PC.

   **Correction made during implementation (see D020):** the first draft
   claimed "at the ROB head the architectural RAT *is* the recovery state, so
   zero new repair logic." That was WRONG for this codebase — an
   implementation-design pass against `ooo_cpu.v` proved it: there is **no
   architectural RAT**. `rat[]` is the *speculative* map, polluted by all the
   younger (about-to-be-flushed) uops; retirement never maintains an arch map.
   And retirement returns freed physical regs to the freelist only
   *incrementally* (one retire at a time via `rob_old`), so it cannot rebuild
   the freelist for the ~31 younger uops that are discarded *without*
   retiring. A load owns **no checkpoint** (only branches/JALR do), so
   branch-style single-cycle restore is impossible.

   **Chosen fix (Hanna): Strategy B-real — loads stay checkpoint-free.**
   - Add an **architectural RAT** `arat[0:31]`: seeded to identity at reset,
     updated at retire (`arat[rob_rd] <= rob_pd` on each writer retire, slot1
     wins a same-cycle WAW). This is the committed arch→phys map.
   - Flush-at-head is a **multi-cycle drain** (rare — fires only on a real
     violation): freeze the front-end, copy `rat <= arat`, empty the ROB,
     and rebuild the freelist ring so its free window lists exactly the
     phys regs **not** in `arat[]`. A ~32-step sweep; negligible IPC cost
     because violations are rare.
   - Livelock-free: the older violating store has committed (drained) by the
     time the load reaches the head, so the replayed load reads the correct
     value and cannot re-violate on the same store.

## ISS / lockstep — NO change

The golden model (`tb/verilator/iss.h`) executes atomically in program order
and compares architectural state at **retire**. A speculative load that is
violated is poisoned, never retires with its stale value, and re-executes
after recovery reading the correct memory — so the retired architectural
result equals the ISS's in-order load. Speculation is invisible to lockstep,
exactly as branch speculation already is. (Test-coverage caveat: bias the
constrained-random generator toward store→load **address reuse** so
violations actually occur and get exercised.)

## Invariants the implementation must hold

- INV-01 LQ alloc at dispatch (in program order, slot0 older than slot1);
  free at **retire**, not WB (a retired load's entry must persist until it
  actually retires so a late store can still violate it — but see INV-09).
- INV-02 A load sets `executed` + captures `waddr`/`bytemask` when it performs
  its port2 read (not at dispatch).
- INV-03 Violation CAM only matches loads **younger** than the filling store
  (`is_younger`), valid, and executed.
- INV-04 Overlap = same word address AND byte-mask intersection ≠ 0.
- INV-05 Poison is sticky on the ROB entry until the load reaches the head and
  flushes.
- INV-06 Flush-at-head reuses the reset-class clears + `is_younger` kill net;
  it refetches from the load's PC (`rob_pc[head]`).
- INV-07 A load-violation flush and a same-cycle branch mispredict: branch
  mispredict (port0) takes priority in the existing restore path; the poison
  survives and re-triggers when the (older) load later reaches the head. (A
  violated load is older than nothing younger that a branch would restore
  past; if the branch is older, the load is squashed anyway.)
- INV-08 Two stores in one cycle: only one store fills per cycle (port2 is the
  sole memory pipe), so at most one CAM sweep per cycle. No multi-store race.
- INV-09 A load cannot be violated after it retires: stores fill at EX, loads
  retire in program order, and a violating store is **older** than the load,
  so it has filled (and been checked) before the load reaches the head.
- INV-10 The conservative IO/NPU replay (`sq_qolder`, region 4/5) is
  unchanged — those loads still replay until older stores drain (strong
  ordering for MMIO/NPU is preserved; speculation applies to plain RAM loads).

## Staged implementation plan (lockstep + IPC gate after each)

- **Inc 0** — add store→load-reuse directed tests + bias the random generator;
  confirm they pass on the *current* conservative core (no RTL change). Locks
  in the oracle.
- **Inc 1** — `ooo_lq.v` (new) + word-granular violation CAM + poison bit +
  flush-at-head, **RAM-region loads only** (IO/NPU keep today's path). Relax
  the IQ gate for RAM loads. Verify lockstep-clean.
- **Inc 2** — integrate cleanly with branch-restore priority (INV-07); stress
  with mixed branch+violation random seeds.
- **Inc 3** — byte-precise overlap (INV-04 byte-mask) instead of word-granular.
- **Inc 4** — **measure IPC** (CoreMark + a pointer-chase microbench) vs the
  conservative baseline; run Quartus STA to confirm the LQ CAM did not erode
  the D019 Fmax; log D020 with the measured numbers.

## Fmax caution

The violation CAM runs **parallel to** the SQ address fill (same cycle a store
computes its address) and is **shallower** than the D019 `pick()` tree, so it
should not become the new critical path. Escape hatch if STA disagrees:
register the violation signal (detect in cycle N, poison in N+1) — the poison
is not timing-critical since it only matters when the load reaches the head.
