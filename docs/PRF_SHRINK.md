# PRF → M9K — design options (Task 1, docs/NEXT.md)

> **DELIVERED 2026-07-12 as D025 (branch `prf-m9k-lvt`): Option A.** 18
> banked M9K blocks + register LVT + folded read + direct/shadow write-first
> bypass. Board top **43,609 → 34,714 LEs (88% → 70%, −8,895)**, M9K
> 95/182, fit 0 errors, timing MET (+17.47 ns), **IPC-neutral** (hello.c
> cycle-identical; prf-tb 300k random + full lockstep clean). See
> DECISIONS.md D025 for the measured record.

> **Autonomy note (2026-07-12):** Hanna delegated this task end-to-end
> ("make the best decision, I'm AFK"). Per the project rule this file is
> still the options sheet — all alternatives are recorded with tradeoffs —
> but the pick (**Option A**) and its rationale are documented here rather
> than waiting for a live decision. DECISIONS.md D025 carries the binding
> record + measured results.

## The target (measured, not assumed)

`ooo_prf:PRF0` is the audit's *other* LE pig: **10,947 LCs** (2026-07-11
audit §1, from the failed D023 fit's per-entity table), tied with the
gshare PHT that D024 just moved to M9K. It is a **6-read / 3-write,
64×32** merged physical register file (decision D013, R10K style).

Why it burns fabric — the exact same disease D024 cured for the PHT:

- an async-read register array (`reg [31:0] regs[0:63]`) has **no address
  register** for Quartus to retime into a block RAM, so the storage stays
  in **fabric flops** (64 words × 32 bits × ~duplication);
- each of the **6 read ports** is a 64:1 × 32-bit combinational mux tree
  over those flops (`assign r0a = rd_bypass(r0a_tag)` …), and the flops
  are effectively duplicated so all six ports can read at once;
- the write-first bypass adds three more 32-bit comparisons per port.

So the lever is the **read/write port network**, exactly like the PHT.

## The structural insight that makes the fold IPC-neutral

The read address of every PRF port is **already a registered value one
stage upstream** — the same argument as D016 (dmem), D022 (imem) and D024
(gshare):

```
SEL cycle          RF cycle              EX cycle
sel*_uop  --edge--> rf_u[i]  --async--> prf_r*  --edge--> ex_a/ex_b[i]
           (reg)    read PRF             (reg into EX operand latch)
```

The read tag consumed in the RF stage is `rf_u[i][U_PS1/PS2]`, whose
next-cycle value is the SEL-stage `sel*_uop[U_PS1/PS2]`. The PRF result is
consumed at **exactly one place** — `ex_a/ex_b[i] <= prf_r*` — one edge
later. So if the read address is registered *into the RAM's own address
register* at the SEL→RF edge (fed from the pre-flop `sel*_uop` tag), a
**synchronous M9K read produces the data during the RF cycle, bit-aligned
with today's async `prf_r*`**. No added latency, no IPC change.

Two facts make this cleaner than imem:

1. **The RF stage never stalls.** `rf_u`, `ex_a`, `ex_b` are clocked
   unconditionally (only `reset` gates them); bubbles are inserted via the
   valid bits, never by holding the data registers. So the M9K address
   register needs **no clock-enable / B012-style hold** — every edge
   captures the next `sel` tag, and killed slots are ignored downstream
   via `rf_v`/`ex_v` exactly as today.
2. **Single consumer.** Nothing reads the PRF except the EX-operand
   latch, so there is no second timing contract to honour.

## Multi-porting a block RAM: the LVT (LaForest & Steffan, FPGA'10)

M9K blocks are at most **simple-dual-port** (1 write + 1 read). To build
6R/3W from them:

- **Reads → replication.** Give each of the 6 read ports its own copy of
  the storage. A write is broadcast to every copy.
- **Writes → banking + a Live-Value Table.** Each of the 3 write ports
  owns a *bank*; a write only touches its own bank. A small **LVT** —
  64 entries × `log2(3)=2` bits — records, per physical register, *which
  write bank last wrote it*. A read consults the LVT to pick the live
  bank.

Grid = **6 read copies × 3 write banks = 18 M9K blocks** (each 64×32,
one M9K; the array is only ~25 % of an M9K, but they can't be merged —
distinct read addresses and distinct write ports). The LVT is tiny
(64×2 bits) and stays a **register array** (async 64:1×2 read is cheap;
its own 6R/3W is trivial at 2 bits wide).

### Read-during-write: the PRF must be bit-exact (unlike the PHT)

The PHT (D024) could accept M9K `OLD_DATA` because predictions are hints
lockstep can't see. **The PRF holds architectural/speculative register
values — it must reproduce the async file's write-first bypass exactly.**
With the fold, an M9K gives `OLD_DATA` for a write that lands on the
read address at the SEL→RF edge, so two external bypass levels rebuild the
async semantics precisely (proof in the module header / DECISIONS D025):

- **direct** (RF-cycle writes): `w*_en && w*_tag==rtag` → `w*_data`
  (the current `rd_bypass`, unchanged);
- **shadow** (one-cycle-older writes, registered copy of the write
  ports): patches the single edge the M9K's `OLD_DATA` drops;
- else the **bank** value, selected by the folded LVT read.

Because physical tags are **single-assignment** while allocated, at most
one of these ever matches — priority is a formality, and an assertion
(`INV-P1`) arms it. Reset/init: banks MIF-init to 0, LVT resets to bank 0,
so untouched tags read 0 (matching the zero-init behavioral file); p0 is
hard-zeroed on read.

## Option A — LVT-replicated M9K PRF  *(chosen)*

18 M9K banks + 64×2 register LVT + folded read + direct/shadow bypass, as
above. Dual-arm module (`ifdef VERILATOR` behavioral / `else` explicit
`altsyncram`) matching the proven **dmem** pattern (DUAL_PORT,
`address_reg_b=CLOCK0`, `outdata_reg_b=UNREGISTERED`,
`read_during_write_mode_mixed_ports=OLD_DATA`, `ram_block_type=M9K`).

- **Area (estimate):** removes ~10.9k LCs of fabric file; adds ~18 M9K
  (of ~107 free on the shipping board top) + ~2k LCs of mux/bypass/LVT
  logic + ~250 flops (LVT, shadow, rtag). **Net ≈ −9k LEs**, matching the
  audit. Takes the board top from 43,609/49,760 LEs (88 %, D024) toward
  ~34–35k (~70 %).
- **Timing:** the async 64:1×6 read cone leaves the fetch/issue path (like
  the PHT did); the RF path becomes M9K-read → 3:1 LVT mux → 6-way bypass.
  Expected timing-neutral-or-better; measured in D025.
- **IPC:** provably neutral (fold + exact bypass). Proven two ways —
  a standalone golden-model unit TB (`make prf-tb`) over ~200k random
  R/W interleavings incl. the RDW corners, and full-core lockstep
  (CoreMark/hello cycle counts identical to main).
- **Interview story:** the fold Hanna has defended three times (dmem,
  imem, gshare) + a textbook FPGA multi-ported-RAM construction (LVT).

## Option B — multipumped (2× clock) banked PRF

Run the M9K at 2× the core clock; a true-dual-port block then serves
2 ops/RAM-cycle × 2 RAM-cycles = 4 ops/core-cycle, roughly **halving the
block count to ~9**.
- Cost: a second (2×) clock domain, RAM/core CDC, and a much larger
  verification surface (timing-closure of the fast domain, phase
  alignment). Real risk against "small verified increments".
- Verdict: **deferred optimization.** M9K is abundant (Option A uses ~18
  of ~107 free); spending verification budget to reclaim 9 blocks that
  cost ~0 LEs is a bad trade now. Documented as the follow-up if M9K ever
  gets tight.

## Option C — shrink the physical register count (64 → 48)

A one-parameter change (`PHYS`), stays async fabric.
- Saves ~1/4 of the file (~2.7k LCs, estimate) with zero new structure.
- Cost: **changes IPC** — fewer rename registers ⇒ the freelist stalls
  dispatch sooner under register pressure; must A/B CoreMark. And it
  leaves the remaining 48 regs in the same async-mux fabric, so it does
  **not** fix the disease, only shrinks it.
- Verdict: **rejected** — smaller win, real IPC risk, doesn't move the
  file to block RAM. (Could be *combined* with A later: a 48-entry M9K
  PRF is just A with a smaller allocator.)

## Option D — status quo

Leave the file in fabric.
- Verdict: **rejected** — it is one of the two structures blocking the
  MLP board demo's routing headroom (audit §1); D024 freed one, this
  frees the other.

## Recommendation → chosen: **A**

Reuses a thrice-proven fold, converts the file to block RAM outright, is
provably IPC-neutral, and its one exact-semantics corner (write-first over
an `OLD_DATA` M9K) is closed by a two-level bypass and pinned by both a
golden-model unit TB and full-core lockstep. B is the future block-count
optimization; C and D are rejected.
