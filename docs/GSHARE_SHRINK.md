# gshare PHT → M9K — design options (awaiting Hanna's pick)

Scope per Hanna 2026-07-12: **gshare only** (PRF/IQ shrinks deferred).
Evidence base: the failed D023 fit's per-entity table + the 2026-07-11
audit (docs/AUDIT-2026-07-11.md §1).

## What the 11,137 LCs actually are (measured, not assumed)

`gshare_bp:BP0` = 11,137 LCs + 5,926 registers + 3,648 memory bits
(fit.rpt). The **BTB data arrays are ALREADY M9K** — Quartus retimes the
fetch address register into the RAM (`ADDRESS_REG_B CLOCK0`) and adds
read-during-write pass-through, so `btb_target/tag/cond` show 0 LCs.
It cannot do the same for the PHT because the PHT read index
`pidx = pc[11:2] ^ ghr` is a **combinational function of two registers**
— no single address register exists to retime into the RAM. Result:

- the 1024×2 PHT lives in fabric flops, **duplicated per read port**
  (~4,096 of the 5,926 registers),
- each of the two fetch slots pays a ~1024:1 × 2-bit async mux tree,
- plus the read-modify-write train path (`pht[tidx] ± 1`, a third
  async read).

So the target is the **PHT read/update network**, not the BTB.

## Key structural insight (makes Option A clean)

`pidx0 = pc0[11:2] ^ ghr` and `pidx1 = pc1[11:2] ^ ghr` with
`pc1 = pc0 + 4` ⇒ pc0[2] ≠ pc1[2] ⇒ **pidx0[0] ≠ pidx1[0], always**
(the xor with `ghr[0]` flips both equally). The two fetch-slot reads
never collide in an even/odd-banked PHT — **the exact D022 imem_banked
trick**, crossbar select = `pc0[2] ^ ghr[0]`.

## Option A — banked sync-read M9K PHT (recommended)

Two 512×2 banks (one M9K each, true dual port: port A = fetch read,
port B = train), even/odd on `pidx[0]`, output crossbar registered with
the read — structurally the D022 imem fold applied to the PHT.

- **Read timing:** the read index must be registered into the M9K one
  edge before use. `pidx` is computable from **next-pc and next-ghr**
  (both known at the prior edge: pc mux output, GHR shift input) — so
  register `pidx` into the RAM address port instead of computing it
  combinationally from the registered pc/ghr. Prediction arrives the
  same fetch cycle as today.
- **The one corner: the first fetch after a redirect.** The redirect pc
  arrives too late to pre-register its pidx. Policy choices inside A:
  - **A1 (simple):** first post-redirect slot predicts direction
    NOT-TAKEN (BTB still provides hit/target — an uncond/JAL still
    redirects at decode as today). Cost: only mispredicted-branch
    shadows, i.e. a second bubble only when a taken conditional sits
    immediately at a redirect target. Estimated ≪1% IPC; measure on
    CoreMark/hello A/B.
  - **A2 (exact):** tiny 2-entry bypass — on redirect, stall the
    direction bit one cycle and mux a same-cycle fabric read of just
    that one PHT entry... adds back an async 1024:1 read for one lane;
    defeats the point. NOT recommended; listed for completeness.
- **Train path:** 2-phase RMW exactly like D021's store-set training
  (cycle 1: read `pht[tidx]` on port B; cycle 2: write ±1). Same-cycle
  read/train collision = M9K OLD_DATA semantics — architecturally
  harmless (predictions are hints; lockstep cannot see them).
- **Reset/init:** PHT must power up "weak not-taken" (2'b01). M9K MIF
  init handles power-up (ERAM mode already proven, D022); KEY0 warm
  reset does NOT reload it — acceptable: a warm-trained PHT is still a
  valid predictor state (document it; alternatively a ~1024-cycle
  post-reset scrub FSM, ~30 LEs, if you want bit-exact warm resets).
- **Estimated recovery (labeled estimate):** ~8-9k LCs + ~4k registers
  freed; +2 M9Ks (of 107 free). Board A&S ~53.2k → ~44-45k (~90%),
  back below the D022 density that routed with margin.
- **Verification:** lockstep is blind to predictor internals, so the
  proof is (1) all suites green, (2) CoreMark/hello cycle-count A/B vs
  main to quantify the A1 policy cost, (3) the INV-style assertion set
  (PHT bank parity invariant, train-RMW pairing).
- **Interview story:** same fold you already defended twice (D016 dmem,
  D022 imem) plus a real µarch policy decision (A1) with measured cost.

## Option B — pipeline the direction into the next stage

Read the PHT synchronously with the REGISTERED pc (no pre-computation),
accept the direction bit one stage later, and redirect on
predicted-taken conditionals from decode instead of fetch.
- Cost: every predicted-taken conditional becomes a 1-bubble redirect
  (like JAL's decode-redirect today). CoreMark is branch-dense —
  estimated several % IPC loss.
- Verdict: **listed as considered-and-rejected** unless you value the
  simpler fetch timing over IPC; measure only if A1's corner bothers
  you.

## Option C — shrink the fabric PHT (fallback, zero risk)

`PHTD 1024 → 256` (a one-parameter change, stays async fabric).
- Saves roughly 3/4 of the PHT flops + mux trees (~6-7k LCs, estimate);
  no timing/pipeline changes at all.
- Cost: 4× more gshare aliasing — CoreMark IPC hit unknown until
  measured (gshare is robust at 256 entries for small codes; CoreMark's
  branch working set may notice).
- Verdict: the quick unblock if A stalls; can also COMBINE with A later
  (a 256-entry M9K PHT is just A with a smaller MIF).

## Recommendation

**A with policy A1.** It reuses a twice-proven fold, kills the fabric
duplication outright, and its one IPC corner is measurable and almost
certainly negligible. C is the emergency fallback; B is documented as
rejected.

**Hanna decides:** A1 / A2 / B / C (or combinations). Implementation
after the pick: new `gshare_bp` internals only — the module interface
to ooo_cpu can stay identical (same-cycle outputs), so the diff stays
contained and lockstep-verifiable module-locally.
