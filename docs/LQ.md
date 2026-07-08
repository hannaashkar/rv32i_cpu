# Speculative Loads + Load Queue (LQ) — design spec

Status: **design confirmed, implementation staged** (2026-07-08).
Owner decisions (Hanna): LQ depth = **8**; recovery = **poison + flush at ROB
head** (Strategy B). Derived from a 3-way adversarial design analysis
(structure / recovery / ISS-lockstep). See DECISIONS.md D020 (added at
implementation).

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

4. **Recovery = poison + flush at head (Strategy B).** On a CAM hit, set a
   `poison` bit on the violated load's ROB entry. Do **not** squash
   immediately. When that load reaches the ROB head, trigger a **single full
   pipeline flush** and refetch from the load's PC. Rationale (the decisive
   design point): a load owns **no checkpoint** (only branches/JALR do), so
   branch-style restore keyed on the load's tag is impossible. But **at the
   ROB head the architectural RAT already *is* the correct recovery state**,
   and retirement already rebuilds the freelist from `rob_old` — so Strategy B
   needs **zero new RAT/freelist repair logic**. Livelock-free: the older
   violating store has committed (drained) by the time the load reaches the
   head, so the replayed load reads the correct value and cannot re-violate on
   the same store.

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
