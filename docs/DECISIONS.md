# Architectural & Project Decisions

One paragraph per decision: what was decided, the options considered, and why.
Decisions are Hanna's; entries are logged so each one can be defended later.

---

## D028 — 2026-07-14 — IQ port-1 clear-and-repick chain → cycle-exact balanced top-two tournament; scheduler pipeline deferred after IQ leaves the timing wall

**Decision:** replace the issue queue's dependent `pick → one-hot clear →
repick` path with one balanced sorted-pair tournament that returns the oldest
and second-oldest eligible ALU entries together. Hanna delegated the
performance-phase architecture call. D027 STA showed all top-20 paths crossing
the old port-1 chain from `rob_head` into IQ operand-ready state, at 38.744 ns
and 32 logic levels. Three options were evaluated:

1. Register issue grants and split select from wakeup. This gives a hard timing
   cut, but adds scheduling latency, changes dependency spacing and IPC, and
   complicates flush and folded-PRF alignment.
2. Bank or payload-split the IQ. This remains a useful area/frequency lever,
   but is broader than the measured second-winner dependency.
3. Compute the two oldest entries in one balanced tournament. This removes the
   measured serial dependency while preserving the current cycle contract.

Option 3 was selected as the smallest evidence-backed architectural change.

**Exact contract:** every leaf is a sorted pair containing its real candidate
and an invalid runner-up. Each `pair_cmb2()` node merges two sorted pairs into
their oldest and second-oldest entries using the existing unsigned modular ROB
age and lower-index tie break. Port 1 takes the runner-up only when port 0
consumed the oldest ALU; otherwise it takes the oldest. The three public grants
remain combinational. No state, pipeline stage, issue latency, wakeup rule,
load replay rule, or recovery behavior changes.

**Proof:** INV-I1 keeps the former pick/clear/repick topology live under
Verilator and compares both raw winners plus the consumed port-1 result every
cycle. The independent public-interface `iq-tb` checks all 162 payload bits,
modular-age and class arbitration, select/load wakeup, masks, dispatch,
replay/done, branch/full flush, and reset. It passes **300,553 cycles**
(300,000 random), **74,571 complete-payload checks**, and **36,515 / 9,816 /
28,240 port selections**, with mandatory occupancy 0–16 and winner coverage
for all 3×16 leaves. Both cores pass 20/20 directed+C, 40/40 rv32ui, 25/25
base/system/NPU random, and 80/80 X/reset; OoO also passes the LQ/SQ/IQ units
and 25/25 violation stress. Every system run is lockstep-clean with zero
divergence. Fresh combined coverage is **99.2% (1522/1534)** across 60 programs
per core with zero failures; every D028 IQ addition is covered, and the same 12
documented lines remain uncovered. `hello.c` is unchanged at **2,013 cycles /
1,882 instret**.

**Performance:** reportable 720-iteration CoreMark is cycle-exact to D027:
**506,132,722 benchmark ticks, 10.122654 s, 71.127589 iterations/s = 1.422552
CoreMark/MHz, 506,197,207 full-run cycles, 519,453,600 instret/lockstep
comparisons, and IPC 1.026**. All official CRCs and reportable-validation
checks pass with zero divergence. D028 therefore completes its merge gate as
a pure implementation/timing change.

**Quartus result:** Analysis & Synthesis is **37,874 LEs**; the routed board
top is **35,096 / 49,760 LEs (71%)**, 15,138 registers, 632,444 memory bits,
and 16 multiplier elements. IQ cost is **8,565 fitted LCs / 2,720 registers**
versus D027's 8,270 / 2,720: +295 LCs and zero state growth. Slow-85C Fmax is
**27.02 MHz**. At PLL /3, setup is +22.994 ns, hold +0.372 ns, recovery
+52.869 ns, and removal +1.653 ns; every timing class is positive and all five
unconstrained counts are zero. The IQ is absent from all top-20 paths. The new
family runs from dmem M9K read through load/JALR/redirect logic to a gshare PHT
M9K address, at 36.433–36.132 ns.

**Clock call:** retain **PLL /3 = 16.67 MHz**. Moving to 25 MHz consumes 20 ns
of the measured setup slack and leaves a theoretical **+2.994 ns**, narrowly
below the predeclared ≥3 ns production gate. A true scheduler pipeline is
deferred because the scheduler is no longer the measured limiter; D029 targets
the new load/JALR/redirect/PHT path first.

**Physical freshness:** a final clean map+fit rerun after the last RTL text
exactly reproduces the documented D028 numeric fit/STA results. With MIF stamp `mlp`,
`quartus_asm rv32i_cpu` completed at 22:44:32 with **0 errors / 0 warnings** and
produced fresh PLL-/3 D028 MNIST `.sof` and `.pof` images. The entire input to
assembly freshness chain is clean. The images remain **unflashed** and are not
hardware evidence; silicon truth remains the earlier LED-walker/CFM image at
16.67 MHz. MNIST inference on the board is still pending. Full design and evidence:
**[IQ_TIMING.md](IQ_TIMING.md)**.

## D027 — 2026-07-14 — SQ forwarding/replay selector → cycle-exact balanced tree; serial path removed, IQ age/select becomes the measured wall

**Decision:** replace only the store queue's source-ordered youngest-match
scan with parallel candidate generation and a fixed 8→4→2→1 reduction tree.
Hanna explicitly delegated the performance-phase architecture call. D026 STA
showed that every top-20 setup path crossed the SQ's serial `m_found/m_age`
chain, so this was the smallest change that could remove the measured wall
without changing the load pipeline. Two more invasive alternatives were
rejected for this increment:

1. Register the SQ query and add a load-pipe stage. That cuts the path more
   deeply, but changes load latency, replay timing, wakeup timing, and IPC.
2. Return to a conservative load policy or weaken forwarding/replay. That
   discards measured speculative-load IPC or changes memory semantics merely
   to make timing easier.

**Exact contract:** each entry forms a 38-bit candidate
`{same_word_match, tag-head, full_word_store, data}` in parallel. A fixed
three-level `youngest_of_two` maximum-age tree selects the youngest store
strictly older than the load. A defensive equal-age tie chooses the
left/lower physical index, exactly matching the old ascending scan's strict
`>` update. `SW` forwards; an `SB`/`SH` selected in the same word requests the
existing replay behavior; no match drives `q_data=0`. The strong-order
`q_older` predicate is reduced separately so unknown-address and
different-address older stores still block MMIO/NPU loads. No register,
architectural state, load latency, or recovery rule changed.

**Proof structure:** the original serial scan remains under `VERILATOR` as
INV-S1 and compares all four public query outputs every cycle. INV-S2/S3 add
ring-window, occupancy, unique-tag, committed-prefix, full fill-identity,
retire/flush target, query-color, and drain-head checks. The independent
public-interface `sq-tb` golden model covers allocation, fill, commit/drain,
backpressure, branch and violation rewind, modular wrap, unknown ordering,
same-word byte-offset cases, multi-match selection, and all eight winner
leaves. It passes **300,087 cycles / 300,088 queries / 45,313 forwards /
90,252 conflicts / 36,668 drains / 2,382 flushes**, including 300,000
deterministic random cycles and every mandatory coverage bin.

**System verification:** both cores pass 20/20 directed+C, 40/40 rv32ui,
25/25 base random, 25/25 system/decode-tail random, 25/25 NPU/MMIO-ordering
random, and 80/80 randomized-reset runs. OoO additionally passes 25/25
load-violation stress. Every run is retirement-lockstep clean. Final combined
line coverage is **99.2% (1488/1500)**; the tree adds covered RTL while the
same 12 documented defensive/configuration and board-facing MMIO lines remain
uncovered. No new RTL bug was found, so the bug log remains B001–B015.

**Performance:** reportable 720-iteration CoreMark is cycle-identical to
D026: **71.127589 iterations/s = 1.422552 CoreMark/MHz, IPC 1.026,
506,197,207 cycles, 519,453,600 retired instructions lockstep-compared**, and
10.122654 benchmark seconds with the official CRCs and `Correct operation
validated`. The rewrite is therefore a pure implementation/timing change.

**Quartus result (MAX 10 slow-85C, MNIST board top, default seed, PLL /3):**

- Analysis & Synthesis: **37,529 LEs** versus 37,589 on D026. The SQ is
  **924 combinational LEs / 596 registers** versus 943 / 596: −19 logic,
  exactly zero state change.
- Routed fit: **34,787 / 49,760 LEs (70%)**, 95/182 M9Ks, 16 multiplier
  elements, one PLL. The SQ is 1,024 fitted LCs / 596 registers (D026:
  1,022 / 596); the two-cell routed variation is placement noise, not state.
- Slow-85C Fmax is **25.47 MHz**, up from 25.10 MHz (+1.5%). At the shipping
  16.67 MHz clock, setup slack is **+20.745 ns**, hold +0.337 ns, recovery
  +51.478 ns, removal +1.295 ns; every reported timing class is positive and
  all five unconstrained counts are zero.
- The old SQ serial names are absent from every top-20 path. All new top-20
  paths are the next wall: `rob_head` through the IQ's relative-age,
  eligibility, select, and wakeup cone into `r1`, with a **38.744 ns data
  delay / 32 logic levels** worst path.

**Clock call:** retain PLL **/3 = 16.67 MHz**. The routed 25.47 MHz Fmax would
leave only about **+0.745 ns** theoretical setup slack at an exact 25 MHz
clock, below the predeclared +3 ns minimum (+5 ns preferred) production gate.
Because the /3 characterization already proves that margin is insufficient,
an expensive /2 compile was not used to manufacture a borderline claim. The
fresh D027 `.sof` and `.pof` were assembled at /3 (0 errors/0 warnings) but
remain unflashed; physical MNIST acceptance is still Hanna's board step.

**Lesson:** balancing a measured serial cone can be completely successful and
still yield a small top-level Fmax gain when a near-equal path is waiting
behind it. D027 removed the SQ from the timing wall with cycle-exact proof;
STA now makes the next architectural decision unambiguous: a true IQ
select/wakeup pipeline is required for a robust 25 MHz—and ultimately
~42 MHz wall-clock parity with the 50 MHz in-order core.

## D026 — 2026-07-14 — LQ violation selector → balanced 8→4→2→1 tree; Fmax 23.51 → 25.10 MHz, LQ leaves the top-20 paths

**Decision:** replace only the 8-entry LQ violation CAM's source-ordered
minimum-age accumulation with a fixed three-level reduction tree. Hanna
explicitly delegated architectural decisions for this phase; the selection
was evidence-driven because every D025 top-20 path crossed the old serial
`m_found/m_age` chain. Two alternatives were rejected for this increment:

1. Registering the store-fill/CAM request offered a larger timing cut but
   introduced delayed-poison correctness around branch restore, ROB-tag reuse,
   and flush-at-head recovery.
2. Compiling out speculative-load recovery for an FPGA profile would trade
   away roughly 2% CoreMark IPC and make simulation and board policies differ.

**Exact contract:** all eight match predicates are formed in parallel. Each
candidate is `{match, tag-head, tag}`; a fixed 8→4→2→1 `oldest_of_two` tree
selects the smallest unsigned 6-bit modular age, with the lower LQ index
winning an equal-age tie exactly like the old 0→7 scan. No hit still drives
`vio_tag=0`. There is no new register, recovery state, or pipeline latency.
The old scan remains under `VERILATOR` as an independent cycle-by-cycle
equivalence oracle (INV-L1); unique live tags and allocation capacity are
also asserted (INV-L2/L3). A public-interface C++ model independently checks
the full allocation/execute/retire/flush lifecycle and selector.

**Correctness bug found on the way:** the new unit-test review exposed B015:
a slot1-only load used `free1` even when slot0 was not a load. At LQ occupancy
seven it dispatched without allocating an entry, so a later violation could
be missed. Allocation is now packed (`free0` for slot1-only, `free1` for the
second load), including the same-edge branch-flush kill. See BUGLOG B015.

**Verification:** `make lq-tb` passes **250,026 cycles**, 218,731 store
probes, and 55,318 matches including modular wrap, multi-hit oldest selection,
byte-mask overlap, physical-index/age disagreement, pre-edge semantics, and
the B015 occupancy-seven reproducer. Final full gates are green on both cores:
20/20 directed+C, 40/40 rv32ui, 25/25 base random, 25/25 system-tail random,
25/25 NPU-ordering random, and 80/80 randomized-reset runs; OoO additionally
passes 25/25 violation stress. All are retirement-lockstep clean, with the
tree-vs-scan oracle live in every OoO run.

**Performance:** reportable 720-iteration CoreMark remains **IPC 1.026** and
passes the official CRC/duration gate: 71.127589 iterations/s,
506,197,207 cycles, and 519,453,600 lockstep comparisons. Versus the D025
same-image run, throughput changes by only −0.0006%; that tiny nonzero delta
comes from B015 correctly consuming the final LQ slot in rare slot1-only
groups, not from the combinational tree.

**Quartus result (MAX 10 slow-85C, same board project/default seed):**

- Fmax **23.51 → 25.10 MHz (+6.8%)**; current 16.67 MHz PLL /3 setup slack
  is **+20.166 ns**, hold +0.307 ns, and all paths are constrained.
- The LQ is absent from every top-20 path. Its map cost is 746 combinational
  ALUTs / 336 registers versus 725 / 336 before (+21 ALUTs, no state); fitted
  LQ cost is 853 LCs / 336 registers versus 840 / 336.
- Whole board top: **34,798 / 49,760 LEs (70%)**, 95/182 M9Ks, 16 multiplier
  elements. This is +84 fitted LEs (+0.24% of the device) versus D025.
- New limiter: dmem load result → dependent memory AGU → the **SQ's serial
  youngest-matching-store forward/replay scan** → IQ load wakeup, 39.156 ns /
  41 logic levels. The old LQ/`rob_poison` cone has been successfully retired.

**Clock call:** keep the shipping board at **16.67 MHz** for now. Fmax 25.10
leaves only about 0.17 ns theoretical setup margin at an exact 25 MHz PLL /2,
which is not production-quality headroom. Balance the now-measured SQ selector,
refit, and sign off the actual /2 configuration only if slow-85C margin is
comfortably positive. The D026 `.sof` was reassembled successfully (0 errors,
0 warnings); physical MNIST flashing remains a separate acceptance step.

## D025 — 2026-07-12 — PRF → 18 banked M9K blocks via an LVT (branch `prf-m9k-lvt`); board top 88% → 70% LEs (−8,895), IPC-neutral

**Context:** the 2026-07-11 audit's per-entity fit table named `ooo_prf` =
10,947 LCs, the audit's *other* LE pig (tied with the gshare PHT that D024
just moved). Same disease: a 6-read / 3-write, 64×32 **async-read fabric
register array** has no address register for Quartus to retime into block
RAM, so the storage stayed in fabric flops, duplicated per read port, each
port a 64:1×32 combinational mux. The lever is the read/write port network.

**Options (docs/PRF_SHRINK.md):** A = LVT-replicated M9K PRF (18 blocks +
register LVT + folded read + 2-level write-first bypass); B = multipumped
2×-clock banked PRF (~9 blocks, but a second clock domain + CDC — deferred
optimization, M9K is abundant); C = shrink the physical register count
64→48 (rejected — real IPC risk, and it leaves the file in async fabric);
D = status quo (rejected). **Hanna delegated the pick end-to-end (AFK,
"make the best decision"); chose A** — it converts the file to block RAM
outright, is provably IPC-neutral, and reuses the thrice-proven fold.

**Mechanism (LaForest & Steffan, FPGA'10):** 6 read copies × 3 write banks
= **18 M9K blocks** (64×32 each); a write goes to its bank in all 6 copies.
A **64×2-bit register LVT** records, per physical register, which write
bank last wrote it; a read looks it up to select the live bank. The whole
file's read address is **folded** into the M9K address registers — fed the
SEL-stage (pre-flop) source tag `sel_uop[PS]`, registered at the same edge
`rf_u` latches, so the synchronous read lands in the RF cycle bit-aligned
with the old async output. Two facts make it cleaner than imem: the RF read
stage **never stalls** (data regs clocked unconditionally, bubbles ride the
valid bits), so **no clock-enable/hold** is needed; and the PRF output is
consumed at exactly one place (`ex_a/ex_b <= prf_r*`).

**Bit-exact write-first over an OLD_DATA M9K (the one real corner):** the
PRF holds architectural/speculative values, so — unlike the D024 PHT hint —
it must reproduce the async `rd_bypass` exactly. An M9K returns OLD data for
a write landing on the read address at the SEL→RF edge, so two external
bypass levels rebuild it: **DIRECT** (this-cycle write ports vs `rtag`) =
the original write-first, and **SHADOW** (a registered 1-cycle-older copy of
the write ports) patches the single edge OLD_DATA drops; else the bank value
picked by the folded `lvt_sel_rf`. Proof: for producer WB cycle W and reader
RF cycle C, C==W → DIRECT, C==W+1 → SHADOW, C≥W+2 → bank (the LVT owner is
≥1 cycle old by then); no overlap, no gap. Physical tags are
single-assignment while allocated (**INV-P1** asserts no two active write
ports share a tag), so at most one bypass ever matches. Dual-arm module like
dmem: `ifdef VERILATOR` behavioral (3 write-bank memories, registered
read = OLD_DATA) / `else` 18 explicit `altsyncram` (DUAL_PORT,
`address_reg_b=CLOCK0`, `outdata_reg_b=UNREGISTERED`, `OLD_DATA`, M9K,
`init_file=prf_zero.mif`). Reset: control regs (`rtag`, `lvt_sel_rf`,
`wen_q`) reset to 0; data (`lvt`, banks, `wtag_q`, `wdat_q`) power up 0 like
the old un-reset `regs`.

**Verification:** a new standalone golden-model unit TB (`make prf-tb`,
`tb/verilator/prf_tb.cpp`) drives the module against the async `rd_bypass`
+ one-cycle read latency over a directed phase (DIRECT/SHADOW/bank/p0/
replication/3-write corners) + **~300k random R/W interleavings** — PASS,
0 failures; the golden is deliberately blind to banks/LVT/OLD_DATA so any
RDW corner fails there. Full-core against the **independent** ISS: OoO
regress 19/19 + riscv-tests 40/40 + random 25/25 + `--vio` 25/25, all
lockstep-clean; **hello.c cycle-identical (2013 cyc / 1882 instret)** —
IPC-neutral by construction and by measurement. In-order core untouched
(19/19; it does not even compile `ooo_prf`). **CoreMark: 421,825,353 cyc /
432,874,206 instret / IPC 1.026, official CRCs — cycle-for-cycle IDENTICAL
to the async-PRF baseline measured on the same tree** (the two builds were
run back-to-back; the fold changes no cycle, as the lockstep-clean →
identical-control-flow argument requires). Adversarial multi-lens review
(fold-timing / bypass-corners / LVT-reset / synth-semantics / wiring), each
finding refuted by an independent skeptic: **5 reviewers, 0 defects
confirmed** — a fourth independent check beyond the unit TB, ISS lockstep,
and synthesis.

**Result (Quartus fit, board top `de10_top` = OoO core + MNIST demo):**
- **Total logic elements 43,609 → 34,714 / 49,760 (88% → 70%, −8,895 LEs).**
  A&S estimate 53,200 → 37,532 (−15,668). Dedicated registers 18,976 →
  15,146 (−3,830). The audit's second LE pig is gone.
- **M9K 95 / 182 (52%)** — the 18 PRF banks all mapped to block RAM
  (confirmed `altsyncram` in the fit hierarchy); ample headroom (dmem 64,
  imem 2, PHT 2, BTB, PRF 18).
- **Fit Successful, 0 errors. Timing MET at the 16.67 MHz board clock,
  worst constrained setup slack +17.47 ns, 0 violations.** The critical
  constrained path is UNCHANGED — `dmem-load → rob_poison` (the D020 LQ
  CAM, ~41.9 ns, ~23.5 MHz-capable); the PRF is off every top-20 path, so
  the fold is timing-neutral (it left the async 64:1×6 mux cone in fabric
  behind). The slow-85C Fmax *panel* reads 18.64 MHz — the pessimistic
  all-paths floor that counts SDC-excluded async paths (same figure as
  D022's board top); the constrained slack is the sign-off number.

**Current-tree reportable performance confirmation (2026-07-14):** the exact
same 720-iteration CoreMark image ran on both models. In-order measured
58.828385 iterations/s (**1.176568 CoreMark/MHz**, 612,038,902 cycles, IPC
0.849); D025 OoO measured 71.127993 iterations/s (**1.422560 CoreMark/MHz**,
506,194,158 cycles, IPC 1.026): **+20.91% CoreMark/MHz**. Both runs exceeded
10 benchmark seconds, printed `Correct operation validated`, matched the 2K
CRCs, and checked ~519.45M retired instructions against the ISS with zero
divergence. `make coremark-compare` preserves this same-image A/B protocol.

**Interview story:** the read-address fold Hanna has now defended four times
(dmem D016, imem D022, gshare D024, PRF D025) + a textbook FPGA multi-ported
block-RAM construction (LVT), verified bit-exact against an independent ISS.

## D024 — 2026-07-12 — gshare PHT → even/odd banked M9K (branch `gshare-m9k-pht`)

**Context:** the 2026-07-11 audit's per-entity fit table showed
`gshare_bp` = 11,137 LCs, the #1 (tied) LE pig, blocking the D023 board
demo at 96% routing congestion. The BTB arrays were ALREADY M9K (Quartus
retimes the pc-only read address into the RAM); the LCs were all PHT-side,
because the PHT read index `pc[11:2]^ghr` is a combinational function of
two registers with no address register to retime — so Quartus kept the
1024×2 array in fabric and DUPLICATED it per read port (~4k of the 5,926
predictor registers).

**Options (docs/GSHARE_SHRINK.md):** A = banked sync-read M9K PHT
(recommended), B = pipeline the direction one stage (rejected: a bubble on
every predicted-taken branch), C = shrink the fabric PHT to 256 entries
(fallback, more aliasing). **Hanna chose A1** (gshare-only scope, deferring
PRF/IQ).

**Key insight that made A clean:** for a fetch pair (pc, pc+4), the two PHT
indices always differ in bit 0 (+4 flips pc[2]; the xor with ghr[0] flips
both parities equally), so slot0/slot1 never collide in banks split on
`pidx[0]` — the exact D022 imem_banked even/odd argument, applied to the
PHT. Two 512×2 M9K banks, bank address = `pidx[9:1]`, output crossbar on
the registered parity.

**Read timing (kills A1's "blind first slot" compromise):** the banks'
address registers pre-load the NEXT cycle's indices, computed from `npc0`
— a mirror of the pcF priority mux in ooo_cpu (reset / lq_flush /
restore / dec_redirect / fd_accept / hold) — and `ghr_nx`, this module's
own GHR next-value. Predictions therefore stay same-cycle on EVERY path
including redirects, so no post-redirect slot ever goes blind. INV-G1
($fatal) re-derives the read index from the live pc/ghr each cycle and
catches any pcF path the mirror misses.

**Training:** 2-phase read-modify-write on each bank's port B (read `tidx`,
write ±1 next cycle) with a 1-deep skid queue per bank; sustained
1 train/cycle alternating banks, 1 per 2 cycles same bank, excess events
dropped (counted `tr_drops`). Predictor state is a hint, never
architecturally visible, so a dropped update is an accuracy detail, not a
correctness issue — which is why lockstep stays exact.

**Sim/synth arms:** behavioral banks (read-first NBA) mirror the
altsyncram BIDIR_DUAL_PORT config with `OLD_DATA` mixed-port RDW; PHT
power-up = weak-not-taken from `synth/pht_init.mif` (checked in) / the
behavioral `initial`. PHT contents deliberately survive KEY0 warm reset
(MIF loads at configuration only; a warm-trained PHT is still valid — BTB
valids and the GHR still reset).

**Verification:** INV-G1 (read-index timing) + INV-G2 (a flat replay-
shadow that catches crossbar-polarity / bank-routing bugs the
architecturally-invisible predictor would otherwise hide — the data-path
check, mirroring imem_banked's INV-F1), both armed every cycle of every
test. OoO 19/19 + 40/40 riscv-tests + 25/25 random + 25/25 `--vio`,
lockstep-clean. **CoreMark IPC 1.026 KEPT** (421.8M cyc, official CRCs,
432.8M instructions lockstep-verified) — identical to the pre-D024
baseline, confirming prediction accuracy is unchanged; hello.c 1989 →
2013 cyc (+1.2%, the train-latency + drop cost). Adversarial review
(3 lenses): 3 minor findings, zero live bugs.

**Result: A&S 53,200 → 46,620 LEs (−6,580, 12.4% of the device freed),
registers 18,976 → 16,995**, PHT now in 2 M9Ks. The budget gate passes.

**BOARD FIT UNBLOCKED (the whole point):** the D023 MNIST-demo top —
which failed to route at 96% LEs on 2026-07-11 (817 / 1,415 unrouted
conflicts, two placements, called structural) — now **FITS: 43,609 /
49,760 LEs (88%), Fitter Successful, 0 errors.** Timing MET at the
16.67 MHz board clock with **+16.8 ns slack** (Restricted Fmax
23.16 MHz — actually UP from D019's ~19.65, because removing the async
PHT read/update cloud shortened the frontend; the new limiter is the
dmem-load → rob_poison LQ path from D020). `.sof` built. NOT yet on
silicon — flashing needs the USB-Blaster (Hanna's step). This confirms
the audit's core thesis: the LE relief had to come from the RTL (PHT →
M9K), not synthesis settings.

## D023 — 2026-07-11 — MLP memory sizing + 7-segment display path: the on-board MNIST demo (branch `mlp-board-demo`)

**Context:** D022 put the board back in business but the memories were demo-
sized (4 KB imem / 1 KB dmem); the MNIST MLP needs ~5 KB of code and ~50 KB
of data (weights dominate). The D022 ERAM recipe made initialized M9K
possible for the first time — this branch applies it to dmem, which is what
makes a data-carrying board program possible at all (there is no loader;
.data must be in the RAM at power-up).

**Hanna's calls (AskUserQuestion):** result display on the **7-segment
displays** (HEX pins added to the qsf — first pin additions since the
original build; verified against two independent DE10-Lite references,
additive only), **8 test images** selected with SW[2:0], and **64 KB dmem**
(round power of two over a tight fit — M9K headroom is plentiful).

**Memory sizing (rtl/mem/dmem.v, imem_banked.v):** synthesis defaults grew
to imem 2048 words (8 KB) / dmem 16384 words (64 KB). dmem's SYNC_READ arm
now instantiates an **explicit altsyncram in simple-dual-port mode** (port
A = byte-enabled write, port B = registered-address read) initialized from
`synth/dmem.mif` — explicit because MAX 10 refuses MIF init on any inferred
RAM (B006/D022). `read_during_write_mode_mixed_ports("OLD_DATA")` pins the
one observable RDW corner to the behavioral arm's nonblocking semantics.
The behavioral (Verilator) arm is bit-identical to before; the byte-enable
write logic is shared verbatim between both arms, so sim-vs-silicon
divergence in the write path is structurally impossible.

**MMIO HEX registers (rtl/soc/mmio.v):** 0x4000000C = {HEX3..HEX0},
0x40000014 = {HEX5,HEX4}; one raw ACTIVE-LOW segment byte per digit, bit 7
= decimal point, reset = all dark. Hardware does not decode digits — the
font lives in software (sw/common/rv32.h) — keeping the RTL a pure 48-bit
register. Both registers read back and are ISS-mirrored (iss.h), so every
HEX access in every test is lockstep-compared; directed test
sw/tests/hex_mmio.S covers reset values, readback, the HEXHI 16-bit
truncation, and neighbor isolation.

**Board program (sw/npu_mlp/mlp_board.c + sw/common/link_board.ld):**
NPU-only classify (one image in systolic column 0), reusing weights.h
verbatim — the 8 demo images are the first 8 of the 32 already-vendored
test images, so no new data was added. Phase 1 self-test classifies all 8
vs the offline numpy integer reference and stores to MMIO_SIM_EXIT: the
Verilator harness ends there (this IS the sim regression), the board
ignores it and enters phase 2 — read SW[2:0], classify, display
[image# | label | prediction] on HEX5/HEX2/HEX0, LEDR9 = correct.
link_board.ld mirrors the real memory sizes (8 KB/64 KB) so exceeding the
board is a LINK error, not silent address aliasing. Program text: 489
words of 2048; data: 12,696 words of 16,384.

**Verified:** regress 19/19 (incl. hex_mmio) + riscv-tests 40/40 + random
25/25 on the in-order core; 19/19 + 40/40 + 25/25 + 25/25 --vio on the
OoO core — all lockstep-clean. Board demo self-test: PASS on both cores,
8/8 images correct (in-order 687,018 cyc IPC 0.817; OoO 376,112 cyc IPC
1.492 — ~23 ms per full self-test at 16.67 MHz). Quartus full-compile
numbers: see the status entry / BASELINE notes for this branch.

---

## D022 — 2026-07-10 — imem → even/odd banked M9K ROM + the real B006 root cause (MAX 10 ERAM config mode); the board top FITS again (48,153 LEs / 97%), .sof restored

**Context:** the D021 board finding — `de10_top` no longer fit the 10M50
(A&S 53,075 LEs vs 49,760; fitter "Can't fit"), no board bitstream buildable
since D020. Hanna's calls for this branch (`imem-m9k`): **even/odd
single-port M9K banks** split on word parity (over replicated-ROM and
true-dual-port options), and **fit-fix-first scope** (imem stays 4 KB; MLP
memory sizing is the next branch).

**Mechanism (rtl/mem/imem_banked.v + the fetch fold in ooo_cpu.v):** word
`i` lives in bank `i&1` at bank address `i>>1`; `pc` and `pc+4` always have
opposite word parity, so two single-port ROMs serve the 2-wide fetch every
cycle, aligned or not (even-bank addr = `(w0>>1)+w0[0]`, odd = `w0>>1`). The
output crossbar un-swaps the pair on the parity **registered with the read**
(`sel_q`) — a combinational select would mis-pair whenever pc has advanced
past a hold. The F/D fold is the D016/D018 argument a third time: the ROMs'
read registers ARE `fd_i0/fd_i1`, with **`rd_en = fd_accept` as the entire
contract** — `fd_v*` are set only in the lowest-priority `fd_accept` branch,
so every edge that asserts the valids also captures `mem[pcF]`; every
redirect nulls the valids so a stale capture is never consumed; the first
`fd_accept` after a redirect captures the redirected pair on the same edge
it re-asserts the valids. Mispredict penalty unchanged; `!fd_accept` is
B012's hold. Init flow: `scripts/hex2mif.py` splits the flat program hex
into `synth/imem_even.mif`/`imem_odd.mif` (checked in, `make mif`),
NOP-padded so board behavior past the program end matches the sim's
NOP-fill, with a `--check` round-trip against the padded image.

**The real B006 root cause, found by the escalation ladder:** the
`ram_init_file` attribute was honored for *contents* but the RAM stayed
uninferred ("MIF is not supported for the selected family" — a high-entropy
proof compile baked the program into 3,459 LEs of logic). Explicit
altsyncram ROMs then failed with the *actual* error: **16031 — "Current
Internal Configuration mode does not support memory initialization or
ROM"**. MAX 10 stores M9K init images in its configuration flash, and the
project had never selected an ERAM-capable internal-configuration mode. One
QSF line — `INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"` —
unlocks MIF init on this family; the misleading family message that blocked
imem since D016 was this mode all along. Proof project (bare imem_banked,
random 1024-word program): **32,768 memory bits / 4 M9Ks / 74 LEs**.
Shipping form: explicit `altsyncram` ROM per bank (`operation_mode("ROM")`,
`init_file`, `clocken0 = rd_en`; registering the ADDRESS is equivalent to
registering the DATA for a ROM, and freezing clocken0 freezes q — same hold
contract), behavioral banks + INV-F1 self-check under `ifdef VERILATOR`.

**A capacity assumption corrected (measure, don't assume):** the "~4-5k LE
logic-ROM imem" premise from the D021 board finding was **wrong** — Quartus
had been constant-folding the 12-word LED demo ROM to **98 LEs** all along
(the D021 STA entity table shows it; the content bit-planes of a 12-word +
NOP-pad image are nearly constant). The genuine LE pig is `gshare_bp`
(**9,354 LEs / 5,926 regs** — PHT and async-read BTB in fabric; a known
future lever). The board fit was recovered not by removing imem's LEs but
by the fitter's packing headroom: A&S 53,004 → **fitted 48,153 / 49,760
(97%)** on the **default seed**, mirroring D021's bare-core 53,140 → 48,302.
The D021-era board failure was evidently placement luck at the same density.

**Verified — the fold is cycle-EXACT on the shipping RTL:** hello.c **1989
cyc / 1882 instret** and CoreMark **421,766,309 cyc / IPC 1.026 / official
CRCs** identical to D021; MLP **59,252,344 cyc bit-identical** to a
pre-fold-main reference build run side-by-side (which also refreshed stale
docs: the NPU path is 627,343 cyc post-D021, not the pre-D020 1.05M).
Suites: OoO regress 18/18 (incl. new `sw/tests/fetch_hold_redirect.S` —
dependent-load backpressure, xorshift-directed mispredicts-while-held,
odd-word redirect targets exercising both crossbar polarities, call/ret
decode redirects), riscv-tests 40/40, random 25/25, `--vio` 25/25, all
lockstep-clean; `LOAD_POLICY=1` spot 25/25; in-order untouched and green
(18/18 + 40/40 + 25/25). INV-F1 (outputs ≡ flat shadow image at the
captured pc/pc+4) armed on every fetch of every run; never fired. No new
bug entry this branch.

**Board result (default seed):** Fitter SUCCESS **48,153 / 49,760 LEs
(97%)**, M9K **11/182** (imem = 4 at 2/bank + 55 LEs of crossbar/adder;
memory bits 44,668), timing **MET at 16.67 MHz — worst-case setup slack
+6.34 ns** slow-85C (all corners positive), **`.sof` rebuilt** — the first
buildable board top since D019, now with the store-set predictor in the
tree. Flashing awaits a connected USB-Blaster (no JTAG cable was attached);
the LED walker on silicon doubles as the bank/crossbar acceptance test (the
12-word loop touches both banks every iteration). The ERAM mode line is a
config-flash-layout assignment only — the sacred pin block is untouched.

## D021 — 2026-07-09 — Store-set memory-dependence predictor (Chrysos & Emer); hello.c 2613 → 1989 cyc (90% of the D020 regression recovered), CoreMark IPC 1.026 kept

**Context:** D020 left an open call — speculation's net effect is governed by
violation frequency because the flush-at-head recovery is a ~46-cycle drain:
CoreMark +2.0% (violations ≈ 0) but hello.c −36% (15 stack-spill violations;
**2613 − 1921 = 692 ≈ 15 × 46**, the drains explain the entire gap). Hanna
chose the industry-standard fix (option c): a **memory-dependence predictor**
that stops re-speculating a load once it has violated. Design validated
pre-implementation by the same 3-way adversarial analysis used for D019/D020
(correctness / fidelity-IPC / implementation-timing); `docs/STORESET.md` is
the binding spec.

**What was chosen and why (options weighed in the analysis):** full **store
sets** (Chrysos & Emer, ISCA 1998 — the Alpha 21464-lineage mechanism) over
(a) the Alpha 21264 1-bit `stWait` table and (b) Intel-style per-load
counters+watchdog. The deciding insight: the IQ already carries a per-entry
older-store wait mask decayed by `sq_unknown`, so ANY of these predictors
reduces to a **dispatch-time mask policy** — store sets costs only the
SSIT+LFST tables beyond the 1-bit variant, and the 1-bit variant then falls
out as a ~10-line degenerate config. Both were built and MEASURED
(`LOAD_POLICY` parameter: 0=conservative, 1=always-speculate — both
verified cycle-identical to D020 — 2=store sets [default], 3=21264 1-bit).
Counters+watchdog was rejected: needs SQ-forward outcome feedback that
doesn't exist, for per-load binary precision the 1-bit table already gives.

**Mechanism (rtl/ooo/ooo_stset.v + dispatch integration; docs/STORESET.md):**
SSIT 64×{v,ssid[3:0]} on pc[7:2], LFST 16×{v,sqpos[2:0]} = SQ slot of the
set's last dispatched store (slot-not-inum: `sq_unknown` then implements
both the wait and the paper's invalidate-at-store-execute for free);
predicted masks are `onehot(LFST) & mask_full` — the AND against the
conservative mask is **INV-P1, the safety bracket**: every wait lies between
the two verified D020 extremes, LQ CAM + flush-at-head repair any
under-wait, tables are pure hints (never checkpointed, lockstep-invisible).
Predicted stores wait too (in-set store→store ordering — required: an
older-slow/younger-fast same-set store pair otherwise livelocks a load into
re-violating every iteration). Same-cycle slot0-store→slot1 LFST bypass
covers co-dispatched `sw/lw` spill pairs. Training is 2-phase (capture at
the CAM hit with the poison write's wrong-path gates, apply next cycle via
`rob_pc[tag]`, borrowing the SSIT lookup ports for that one cycle) so
**zero logic lands after the LQ CAM** — the D020 critical path. Cyclic decay
every 2^16 cycles.

**Bug found+fixed on the way (B014):** a CAM hit in the exact
`lq_flush_start` cycle trained against a ROB entry the flush cleared at that
same edge — caught by the INV-P7 assertion (training-reads-live-ROB-entry)
on riscv-test `ld_st` in one regression run, zero debugging. Fix: the
capture gate needs `!lq_flush_start` (restore_en can't cover it — branch
mispredicts are suppressed during a violation flush). The
assertions-with-the-feature methodology paid for itself immediately; see
BUGLOG B014.

**Result — the 4-policy measured table (all lockstep-clean):**

| build | hello.c cyc | hello vio | stset_precise (20-iter ptr chase) | CoreMark IPC |
|---|---|---|---|---|
| 0 conservative | 1921 | 0 | 618 | 1.006 (D020) |
| 1 speculative | 2613 | 15 | 2149 | 1.026 (D020) |
| **2 store sets** | **1989** | **1** | **609** | **1.026** (421.77M cyc, CRCs official) |
| 3 21264 1-bit | 1989 | — | 698 | — |

hello.c recovers **90%** of the regression (residual 68 cyc = one
irreducible training flush + short trained waits; amortizes to ~0 on long
programs — CoreMark proves it: the FULL +2.0% is kept). `ld_st` violations
49 → 31 (the rest are single-shot static sites no PC-indexed predictor can
help — same reason the `--vio` random suite keeps its full recovery
coverage, by construction). **Honesty on policy 2 vs 3:** on hello.c they
tie (both eliminate re-speculation; conservative waits there cost ~nothing —
the 692=15×46 arithmetic predicted exactly this). The store-set *precision*
shows where an unrelated slow-address older store coexists with a trained
load: the loop-carried pointer-chase microbench (`stset_precise.S`) measures
**609 vs 698 (−12.7%)**, and store sets even beats conservative (618) —
first-cut caveat: an earlier non-loop-carried version of the microbench
measured 2==3 exactly because in-order retirement hid the load's issue time;
the redesign note is in the test header.

**Result — verification:** unit TB (golden-model, 200k random cycles + all
merge/bypass/decay/alias directed cases) clean; OoO **17/17** directed
(3 new suites: `stset_predict.S` violate-then-retrain 6→1 violations,
`stset_pair.S` co-dispatch bypass + in-set chain + stale-LFST self-heal,
`stset_precise.S`) + **40/40** riscv-tests + **25/25** random + **25/25**
`--vio`, all lockstep-clean with new invariant assertions armed (mask-subset,
one-hot, no-self-wait, mask⊆live-unknown-slots via a debug-only
`unknown_raw` port, training-liveness, ROB-head watchdog); policies 0/1/3
spot-regressed 17/17; in-order untouched (17/17 + 40/40 + 25/25);
`quartus_map` 0 errors / 43 warnings (unchanged count).

**Result — Fmax/LE (bare-`ooo_cpu` STA, D019/D020 method):** the
characterization device is now **capacity-saturated**: 4 of 5 fit attempts
failed to place at all (seed 1, seed 2, an SSIT=32 trial, a minimize-area
register-packing trial — every one "Can't fit" at 96% LEs), and the
surviving fit (seed 3) closed at **48,302 / 49,760 LEs (97%)** — net
**+64 LEs / +160 registers vs D020's 48,238** (fitter packing absorbs most
of the predictor's ~400 FFs of table state). **The predictor is NOT on the
critical path**: its full lookup chain (SSIT read → LFST → onehot → mask
AND → IQ mask flop) is **19.2 ns** (~50 MHz-capable, positive slack at the
20 ns constraint), the worst path touching any predictor register is
41.9 ns, and the design's actual critical path — **50.7 ns = Fmax
19.55 MHz** — contains zero predictor nodes (dmem sync-read load data →
result bypass → JALR target → BTB target write in `gshare_bp`, a path shape
present since the D018 BRAM port; 80% of it is routing: 40.4 ns
interconnect vs 10.0 ns cell over 24 logic levels). The drop vs D020's
26.32 MHz is **fit-luck at the 97% cliff** (routing congestion), not
predictor logic — and the SSIT=32 trial proved table size doesn't decide
the fit (saved ~390 mapped LEs, still failed), so the pre-analyzed escape
(`SSIT_AW=5`, unit-tested via `make stset-tb STSET_AW=5`) does not ship.
**Board-project finding (new information, PRE-EXISTING condition):** a full
compile of `synth/rv32i_cpu.qpf` (`de10_top`) surfaced that the board top
**no longer fits the 10M50 at all** — and a control map of predictor-free
`main` proves it predates this branch: main maps to **51,225 LEs (103% of
49,760)**; with the predictor, 53,075 (107%). The D020 merge gate was
`quartus_map` *error-count* only, which does not catch capacity overflow —
the board has been over capacity since the LQ landed (last successful board
fit was D019's 44,422 LEs). The fix is the already-roadmapped Task 3:
**imem → M9K block RAM via `ram_init_file`**, which frees the ~4-5k LEs the
4 KB logic-ROM imem burns and is now *required* (not just the MLP-demo
enabler) for any board bitstream. Until then the board `.sof` cannot be
rebuilt from main — with or without this branch.

## D020 — 2026-07-08 — Speculative loads + load queue (LQ) with poison + flush-at-head recovery; CoreMark IPC 1.006 → 1.026 (+2.0%)

**Context:** Before this, OoO loads were **conservative** — a load issued only
once every older store's address was known (the IQ `mask==0` gate). A load
therefore stalled behind any un-executed older store even when they targeted
different addresses, leaking IPC on pointer/list/struct code. The goal (Task 2)
was to let a load issue *early* (speculating no conflict) and detect/repair the
rare real store→younger-load ordering violation. `docs/LQ.md` is the binding
spec.

**What Hanna chose (from a 3-way adversarial design analysis — structure /
recovery / ISS-lockstep):** LQ depth **8**; recovery = **poison + flush at the
ROB head (Strategy B-real)**. A design-pass against `ooo_cpu.v` corrected the
first draft's assumption that "the arch RAT is the recovery state, zero new
logic": there is *no* architectural RAT and retirement returns freed phys regs
only incrementally, and a load owns no checkpoint — so branch-style single-cycle
restore is impossible. The real mechanism therefore adds an **architectural RAT
`arat[]`** (committed at retire) and makes a violation a **multi-cycle
flush-at-head drain**: freeze the front-end, `rat<=arat`, empty the ROB, and
rebuild the freelist ring from the arch map (one phys tag per cycle). Rare
(fires only on a real violation) so the drain cost is negligible on real code.

**What was implemented (branch `ooo-iq-pipeline`):**
- `rtl/ooo/ooo_lq.v` (new): 8-entry LQ; alloc at dispatch (program order), set
  `executed`+`waddr`+`bytemask` at the port2 read, free at retire. A
  combinational **violation CAM** fires when a store fills its address against
  every valid+executed **younger** LQ entry that overlaps in word-address AND
  byte-mask; the oldest such younger load is poisoned.
- `SPEC_LOADS=1` param on `ooo_iq` relaxes the load gate for **RAM** loads only
  (IO/NPU keep strong-ordering replay, INV-10). `arat` + `rob_poison` +
  flush-at-head FSM + per-cycle freelist rebuild in `ooo_cpu.v`.
- ISS/lockstep unchanged: a violated load never retires its stale value and
  re-reads after recovery, so speculation is invisible to the golden model
  (exactly as branch speculation already is).

**Bug found + fixed on the way (B013):** the load-violation flush-at-head did
**not** clear the issue queue — it reused the branch-mispredict path with
`flush_tag = head_tag − 1` intending "everything is younger than head−1," but
the 6-bit relage predicate makes `relage > 63` always false, so it cleared zero
IQ entries. Surviving pre-flush IQ entries then re-issued post-flush with
reallocated physical registers and corrupted the fetch stream (`ld_st` ran to
its `fail` path). Fix: a dedicated `flush_all` port on `ooo_iq` (unconditional
clear), driven by `lq_flush_start`. See BUGLOG B013. Caught by lockstep on the
official riscv-test `ld_st`, root-caused with a cycle-stamped RTL trace (the
same ROB tag issuing twice with different `ps1`/`ps2` — a survived-entry
signature, NOT the pre-flush-branch race the WIP handoff hypothesized).

**Result — correctness:** OoO **14/14** directed + **40/40** riscv-tests
(incl. `ld_st`, ~49 real violation+recovery events, lockstep-clean) + **25/25**
plain random + a new **25/25 `--vio`** stress suite (violation-forcing pattern
injected into the random generator: **1185** real violations across the seeds,
all lockstep-clean). The plain seeds are byte-identical to before, and the
in-order core is untouched (14/14 + 40/40 + 25/25). The `--vio` generator mode
closes the LQ.md Inc-0 coverage gap: the plain seeds essentially never violate
(0 across 25), so without it the recovery path was exercised only by two
directed tests.

**Result — IPC, and the honest tradeoff (needs a Hanna call):** the net effect
of speculation is **entirely governed by how often loads actually violate**,
because the "Strategy B-real" recovery is a **heavy ~46-cycle flush-at-head
drain** (the ~64-cycle freelist rebuild + refetch). Measured both ways
(`SPEC_LOADS=1` vs `0`, otherwise-identical builds, all lockstep-clean):

| Workload | violations | conservative | speculative | Δ |
|---|---|---|---|---|
| **CoreMark** (432.9M instr) | ~0 (rare) | IPC 1.006, 430.4M cyc | IPC 1.026, 421.8M cyc | **+2.0%** |
| **hello.c** (1882 instr) | 15 | 1921 cyc (IPC 0.98) | 2613 cyc (IPC 0.72) | **−36%** |
| `ld_st` / `lq_violation.S` | 49 / 2 | faster | much slower | worst case |

So speculation **wins on violation-sparse code** (CoreMark: violations amortized
over hundreds of millions of instructions → +2.0%, both CRC-correct) but
**loses badly on violation-dense code** (hello.c's recursion spills the stack;
each stack store→reload violates → 15 × ~46-cycle drains dominate a 1882-instr
program → −36%). This is NOT a bug — it is the designed cost of a
checkpoint-free load (Strategy B trades per-load HW for a rare-but-expensive
drain). **Open architectural question for Hanna:** (a) keep `SPEC_LOADS=1` (bet
on real workloads being violation-sparse, like CoreMark); (b) default it OFF and
enable per-program; or (c) make speculation *cheaper to recover* — e.g. a
cheaper squash than the full freelist rebuild (checkpoint the freelist head at
each spec load), or a **store-set / dependence predictor** that stops
speculating a load once it has violated (the standard fix — turns hello.c's
repeated spills back into conservative loads after the first violation). The
recovery cost, not the CAM, is the real lever here.

**Result — Fmax (Quartus 20.1, 10M50DAF484C7G, `ooo_cpu` top, slow-85C):**
**Fmax 26.32 MHz**, fit 0 errors, 48,238 LEs (97 %, up from D019's 44,422 — the
LQ + CAM cost), 16 DSP. **The LQ CAM did NOT erode the D019 19.65 MHz wall** —
26.32 ≥ 19.65. The worst-case path *is* now LQ-adjacent (load-uop →
violation-CAM overlap → `rob_poison[]` set), exactly where LQ.md's Fmax-caution
predicted it might land, but it still clocks above the D019 wakeup limiter, so
the escape hatch (register the violation: detect in N, poison in N+1) was not
needed. Method caveat: this is a self-contained **bare-`ooo_cpu`-top** STA
project (a `create_clock` on the raw `clk`, false-paths on reset/switches/leds),
the same style used to characterize D019/D018; the number is directly
comparable to the 19.65/8.42 lineage. An exact same-fitter-run A/B on the pre-LQ
RTL was attempted (git worktree at commit 847dc31) but that map was
pathologically slow on this machine and was abandoned — the standalone 26.32 MHz
measurement stands on its own and answers the question (CAM did not erode Fmax).
LEs at 97 % are tight; the on-board OoO top still needs the D018 PLL retarget and
lives on the separate `ooo-bram-port` branch — this STA is a characterization
build, not a board bitstream.

**Honest scope:** the OoO core still needs ~42 MHz to tie the in-order core's
50 MHz wall-clock (perf = IPC × Fmax; D018/D019). Speculative loads add IPC, not
Fmax — the deeper 2-stage pipelined scheduler remains the separate future step.

## D019 — 2026-07-08 — OoO issue-queue select rewritten as a log-depth tree; Fmax 8.42 → 19.65 MHz (IPC-neutral)

**Context:** D018 found the OoO Fmax capped at 8.42 MHz by the issue-queue
select+wakeup path (~118 ns). The un-pipelined scheduler is the classic OoO
limiter. Hanna chose to attack it. An adversarial 3-way design analysis
(cycle-accuracy, correctness, FPGA-timing) established that the *dominant*
cost was NOT the wakeup but the O(16) **serial oldest-first age-scan** in
`pick()` (~75% of the path) and its port0→port1 chaining, and that the
obvious "register the grant" 2-stage split would silently cost 1 bubble per
dependent pair (IPC loss). The IPC-neutral path is to shorten the scan while
keeping the tag broadcast same-cycle.

**What was done (branch ooo-iq-pipeline, decision D019, two verified increments):**
- **1a — balanced-tree `pick()`.** Replaced the 16-deep serial min-chain with
  a log-depth reduction tree (16→8→4→2→1, ~4 combine levels). `cmb2` keeps
  the older candidate and, on an age tie, the lower-index (left) operand —
  bit-identical to the serial loop's strict `<` tie-break, so the grant index
  is unchanged.
- **1b — parallel port-1 select.** port1's pick no longer re-scans
  `elig_alu` minus port0's grant (which serialized it behind port0). Instead
  the oldest AND second-oldest ALU are found in parallel (2nd = find-first
  with the 1st winner's one-hot cleared) and port1 is a terminal mux:
  substitute the 2nd only when port0 actually took the 1st ALU entry.
  Preserves the exact "exclude port0's actual grant; branch-on-port0 is a
  no-op exclusion; CSR-oldest lands on port1" semantics.

**Result (Quartus 20.1, 10M50DAF484C7G, OoO top):** STA slow-85C **Fmax
19.65 MHz** (was 8.42) — a **2.33× clock improvement** — fitter 0 errors,
44,422 LEs (89%, no bloat vs baseline). **IPC bit-identical (1.008):**
`hello.c` cycles/instret unchanged (1914/1882); OoO 12/12 regress + 40/40
riscv-tests + 25/25 random seeds all lockstep-clean, zero divergence. The new
STA critical path is the load-result → `wakes()` → `r2` ready-bit wakeup
(~50.9 ns) — i.e. the scan is gone and the residual limiter is the wakeup
broadcast, exactly as predicted. PLL retargeted 50 MHz /7 → **/3 = 16.67 MHz**
(≈15% margin under 19.65). Options weighed: (a) bank 19.65 + move on [CHOSEN
— clean, honest, IPC-neutral, defensible]; (b) push the true 2-stage
pipelined scheduler now [~40–50 MHz but IPC-risked, large — SCOPED AS FUTURE
WORK]; (c) increment 1c `mask_zero` flop for ~22–25 MHz [deferred — still
short of break-even].

**Lesson (interview-grade):** perf = IPC × Fmax, and the OoO core needs
Fmax ≥ ~42 MHz just to TIE the in-order core's 50 MHz wall-clock (its IPC
edge is only +18.8%). The tree/parallel-pick rewrite is a real, measured,
zero-IPC-cost 2.33× — but realizing the OoO's IPC win on THIS board requires
the deeper pipelined scheduler (which does risk IPC and is a separate,
IPC-measured, Hanna-signed-off increment). Attacking the *scan* first was
correct: it is where the timing was, it was provably IPC-neutral, and its STA
result is what tells us the wakeup broadcast is the next wall.

## D018 — 2026-07-07 — OoO core FPGA board port; clocked at 7.14 MHz (issue-queue Fmax cap)

**Context:** After the in-order core reached the board (D016/D017), the goal
was to run the 2-wide OoO core (ooo_cpu) on the DE10-Lite too. Hanna chose
"BRAM port first, LQ later" and green-lit the implementation.

**What was done (branch ooo-bram-port, NOT merged — main stays in-order):**
- dmem `SYNC_READ=1` on ooo_cpu with an IPC-neutral load fold, same principle
  as the in-order core: the load result lands in the SAME writeback cycle it
  did before, so load-to-use (2 cyc), wakeup and the mispredict path are
  unchanged. The RAM select is deferred to WB —
  `wb_result2 = wb2_use_dmem ? dmem_rdata : wb_val[2]` — feeding the three
  consumers (PRF write, EX bypass, ROB value). SQ-forward/MMIO/NPU are
  captured into wb_val[2] at EX→WB; a plain RAM load takes the registered
  dmem read in WB. No combinational loop (the registered read breaks
  addr→data). imem left combinational: it is not on the critical path, and
  would not infer M9K anyway (same MAX 10 initialized-ROM limit as in-order).
- de10_top switched from cpu_pipeline to ooo_cpu (drop-in, same interface).

**The finding:** STA gives **OoO Fmax = 8.42 MHz**. The critical path is
ENTIRELY inside the issue queue (`ooo_iq:IQ0` u[0] → r2, ~118 ns): the
un-pipelined select + wakeup + tag-broadcast across 16 entries — the classic
OoO Fmax limiter — on MAX 10's budget fabric. imem/dmem are not on it.

**Decision:** clock the OoO core at 7.14 MHz (PLL `clk0_divide_by=7`) with
margin instead of pipelining the scheduler now. Timing MET (+9.35 ns), dmem
block RAM (103 segments), 0 errors; the OoO walker runs on the board
(~1.7 s/step). Options weighed: (a) run slow now [chosen — cheap, proves
OoO-on-silicon], (b) pipeline the IQ select-wakeup [big stage, raises Fmax,
changes IPC — deferred], (c) keep OoO sim-only.

**Lesson (worth stating in an interview):** wall-clock perf = IPC × Fmax. The
OoO core wins per-MHz (+18.8% IPC) but its 7× lower Fmax makes it ~6× slower
on THIS board. Realizing the IPC win on hardware requires pipelining the
issue queue — the recommended next OoO stage.

## D017 — 2026-07-07 — PLL clock + real .sdc for honest timing closure (B005)

**Context:** The CPU had been clocked by bit 25 of a free-running counter (a
"ripple" clock, ~0.75 Hz) with no timing constraints — setup slack −13.05 ns,
no meaningful Fmax. B005.

**Decision (Hanna chose "PLL + SDC, self-paced demo"; options offered:
SDC-only on CLOCK_50, or measure-first):**
- A MAX 10 ALTPLL turns the 50 MHz board oscillator into a clean CPU clock
  (`pll.v`, 1:1) with a `locked` signal; the core is held in reset until the
  PLL locks, then the KEY[0] button is double-flopped into the CPU domain.
  The ripple divider is gone.
- The project's first real `.sdc`: `create_clock` on CLOCK_50 +
  `derive_pll_clocks` + `derive_clock_uncertainty`; false-paths on the async
  KEY/SW/LEDR pins. The PLL is instantiated directly (not a generated IP
  blob) so the clocking is self-contained and version-controlled.
- Because the CPU no longer runs at a human-visible rate, the LED demo paces
  itself in software (a delay-loop walker, `sw/demo/led_demo.S`).

**Result (Quartus 20.1, 10M50DAF484C7G, in-order top):** Fitter 0 errors;
STA slow-85C **Fmax = 53.95 MHz** — meets 50 MHz with +1.466 ns setup slack,
0 unconstrained clocks/ports. The synchronous BRAM memories (D016) removed
the async fetch/load critical paths that made this closable. Frequency was
confirmed by STA as agreed; 50 MHz stands with ~8% headroom.

## D016 — 2026-07-07 — Synchronous-read memories for M9K, folded into the pipeline (B006)

**Context:** The in-order core's imem/dmem used combinational (async) reads,
which cannot map to MAX 10 M9K block RAM (they need a registered read). This
cost ~12.5k logic registers and left 0 block-RAM bits (B006), and the long
async memory paths are a big part of the timing failure (B005).

**Decisions taken (Hanna: "pivot to B005/B006", in-order first, minimal /
stall-based latency):**
1. *Bring-up vehicle* — do the memory rework on the in-order core first
   (small, isolates bugs), then port to OoO. dmem/imem gained a `SYNC_READ`
   parameter: the in-order core sets it, the OoO core keeps combinational
   reads (unchanged) until its own memory stage.
2. *Latency handling* — the "extra" BRAM cycle is absorbed by **folding**,
   not stalling. Synchronous BRAM adds one read-latency cycle, but the
   pipeline already had a register at each memory output (the IF/ID
   instruction latch and the MEM/WB mem-data latch). Those latches are
   folded *into* the memories' own read registers, so the load-use timing,
   forwarding and 2-cycle mispredict penalty are all unchanged — **IPC is
   identical**. (Options considered: add a load-use stall cycle — simpler
   RTL, small IPC loss; or a full MEM1/MEM2 memory pipeline — more RTL. The
   fold gives the best of both here because the registers already existed.)
3. *Fetch squash* — with imem's registered output serving as the Decode
   instruction, wrong-path/startup slots are squashed to a NOP via the
   existing pipeline `valid` bit instead of inside IF/ID; imem gets a `hold`
   enable mirroring the IF/ID stall (B012).

**Result:** dmem infers block RAM; imem stays logic on MAX 10 (initialized-
ROM MIF limitation) but is structurally M9K-ready and no longer on the async
critical path — full block-RAM imem via `ram_init_file` is deferred to the
on-board large-program stage. Both cores pass full lockstep verification.

## D015 — 2026-07-03 — MNIST MLP quantization scheme (executed under the
## "all done" directive; decided by Claude, documented for review)

784→32(ReLU)→10 MLP, trained offline in numpy (`scripts/train_mlp.py`,
seeded, 97.10% float). Quantization: **symmetric per-tensor int8** with
TFLite-style fixed-point requantization — `h = clamp((acc*M1 + rnd) >>
N1, 0, 127)` in int64 — over (a) asymmetric/per-channel quantization
(better accuracy headroom, but zero-point cross terms and per-channel
scales complicate both the C driver and the defense story for zero gain
at this accuracy: integer pipeline hits 97.13%, above float) and (b)
power-of-two scales only (simplest requant — a bare shift — but cost
~1% accuracy in trials elsewhere; the int64 multiply happens 32× per
batch, negligible next to 100K MACs). The hidden scale is calibrated
(`sh = max_activation/127` over 1000 training samples) because the naive
`sh = 1/127` saturates (int accuracy collapses to 60%) — the script
auto-selects and records the choice. Layer 2 keeps raw int32 logits +
argmax (classification needs no requant). Batch = 4 images through the
4 array columns for full utilization. Bit-exactness chain: numpy integer
reference → exported goldens → on-core soft int8 path → NPU path, each
step compared exactly.

## D014 — 2026-07-03 — NPU: MMIO-mapped 4×4 output-stationary systolic
## array with hardware ordering interlocks (executed under the "all done"
## directive; decided by Claude, documented for review)

Full spec in docs/NPU.md. Four choices and their alternatives:

1. **Interface: MMIO region 0x5xxx_xxxx** over custom instructions.
   Zero decoder changes, works identically on both cores, plain-C
   driver, and the OoO core's SQ already makes MMIO side effects
   non-speculative. Custom matmul instructions would save ~9 stores per
   tile but touch decode/rename/IQ on the OoO core — revisit only if
   the measured MMIO overhead justifies it.
2. **Dataflow: output-stationary** over weight-stationary (TPU-style)
   and over a flat combinational MAC array. OS keeps the 16 partial
   sums in the PEs across GO commands, so K-tiling (the common loop:
   784 deep in layer 1) needs no C read-modify-write traffic — just
   stream new A/B tiles and GO. Weight-stationary only wins when one
   weight tile is reused across many activation tiles, which a batch-4
   MLP never does (weights change every k-step). A combinational MAC
   array is not a systolic array — fails the roadmap deliverable and
   teaches nothing about dataflow timing.
3. **Tile buffers: 4×4 registers with accumulate-across-GO** (16 B A +
   16 B B) over K-deep staging SRAM (e.g. K=256: 2 KB). Deep staging
   amortizes CTRL traffic but costs ~16K FFs while B006 (no BRAM
   inference yet) is still open — the register-tile design is honest
   about today's FF-memory reality and keeps the unit fully testable.
4. **Ordering: hardware interlocks, software never polls.** OoO: IO
   loads replay until every older store has drained AND the array is
   idle (`busy_next`); the SQ head backpressures (`mw_ready`) instead
   of draining into a busy NPU. In-order: NPU accesses stall in EX on
   `busy_next`. Alternative — software delay loops / poll protocols —
   rejected: unverifiable timing contracts, and the interlock is what
   makes the instantaneous ISS mirror lockstep-exact (busy is
   architecturally unobservable). Found+fixed latent B010 on the way.

## D013 — 2026-07-03 — 2-wide OoO microarchitecture (executed under the
## "all done" directive; decided by Claude, documented for review)

Full spec in docs/OOO.md. The five structural choices and their
alternatives:

1. **Rename: merged PRF (R10K)** over P6 values-in-ROB. One value copy,
   no ARF write traffic, the scheme modern cores use (interview value);
   costs a free list and freeing discipline. 64 physregs = 32 arch + 32
   in-flight (matches ROB depth, so renaming never starves before the
   ROB fills).
2. **Recovery: per-branch RAT checkpoints (8)** over ROB-walk (slow,
   variable latency) or retire-time RRAT squash (adds resolve-to-retire
   latency to every mispredict). A checkpoint is only ~220 bits on FPGA
   FFs; 8 in flight covers CoreMark's branch density. Checkpoints are
   freed at retire, so out-of-order branch resolution needs no special
   casing — nested restores always land on live older checkpoints.
3. **Issue: unified 16-entry queue** with select ≤3 (port-bound: ALU+br,
   ALU+CSR, mem) over split queues (more tuning knobs, more logic).
   Select-time tag broadcast for 1-cycle ops gives back-to-back
   dependents; loads broadcast at writeback because they can replay.
4. **Loads: conservative disambiguation** — issue only past
   known-address older stores, forward only exact full-word matches,
   replay past partial overlaps. Costs IPC vs speculative loads +
   store-sets, but eliminates the LQ, memory-order violations, and the
   replay-storm class of bugs. The LQ returns with speculation as its
   own measured stage.
5. **Stores commit at retire** (≤1/cycle) — keeps all MMIO side effects
   non-speculative for free.

## D012 — 2026-07-03 — Full Zicsr scaffold + pipeline valid bit for instret

Two coupled choices for the measurement CSRs (rdcycle/rdinstret). (1) CSR
scope: Hanna chose a **full Zicsr scaffold** — a `csr_file` module with
generic address decode and all six instruction forms (CSRRW/S/C, register
and immediate) — over a counters-only read path. Costs more decode and
test surface now, but mstatus/mtvec/mepc slot into the same case statement
when traps arrive, with no datapath rework. mscratch is implemented as the
first writable CSR so the write path is tested logic rather than dead
scaffolding; counter CSRs are read-only (writes dropped until traps can be
raised). (2) Retirement counting: Hanna chose a **1-bit valid flag**
flowing IF→WB through the pipeline registers (flushes/bubbles clear it;
instret increments when a valid instruction reaches WB) over a
count-non-NOPs heuristic, which would miscount real NOPs in compiled code
— noise in the exact number (IPC) this stage exists to produce. The valid
bit is also groundwork the OoO core needs regardless. Placement: CSR ops
execute in EX (read + write commit there) — safe because nothing that
reaches EX can be killed in this pipeline (no traps; mispredicts flush
only IF/ID + ID/EX), and the read value returns through the existing EX
result mux so forwarding needs no changes.

## D011 — 2026-07-03 — B007 fix: latch forwarded store data only (F1)

EX/MEM will capture `rs2_fwd_base` (the forwarded rs2) instead of raw
`rs2_dataE`. The considered alternative — an extra WB→MEM store-data bypass
that removes the `lw x5; sw x5` load-use stall — was declined for the
baseline to keep MEM simple; can be revisited as an IPC optimization with
its own measurement.

## D010 — 2026-07-03 — Keep combinational memories for the baseline (Eb)

Byte/half load-store support is added on top of the existing combinational
imem/dmem. The synchronous-read/BRAM rework (fixes BUGLOG B006, changes
fetch/load latency and the hazard window) is deliberately deferred to its
own post-baseline stage, so the "before" measurements reflect today's
microarchitecture and memory is only redesigned once, together with the
PLL/timing work.

## D009 — 2026-07-03 — LUI/AUIPC through the ALU (D1)

U-type immediates go through the normal ALU path: LUI = pass-operand-B,
AUIPC = ADD with a new pc-vs-rs1 mux on operand A. Avoids widening the WB
mux; the operand-A pc mux is shared with jump/branch target logic.

## D008 — 2026-07-03 — Jumps resolve in EX via the redirect path (C1)

JAL target = pc+imm (existing branch-target adder), JALR target = ALU
rs1+imm; rd receives pc+4. Jumps reuse the mispredict/redirect machinery
and are added to the BTB, so repeat encounters are free; a first-seen jump
costs the normal 2-cycle redirect. The early-JAL-in-ID alternative (1-cycle
first-visit saving, extra PC mux + ID adder + hazard cases) was declined —
the BTB erases most of its benefit.

## D007 — 2026-07-03 — Dedicated branch comparator in EX (B2)

Branch conditions (BEQ/BNE/BLT/BGE/BLTU/BGEU) come from a small dedicated
comparator on the forwarded operands, not from ALU flags. ~70 extra LEs
buys a shorter branch-resolve path (the EX redirect path is the current
critical path) and the ALU/branch-unit split the future OoO core needs.

## D006 — 2026-07-03 — ALU decode flattened to funct3-based scheme (A2)

Replace the two-level ALUOp/alu_control decode with direct funct3-indexed
operation select, instr[30] disambiguating ADD/SUB and SRL/SRA, and the
opcode class gating whether funct7 participates at all. This makes bug
B004 (immediate bits spoofing funct7 on I-type) structurally impossible,
costs the same LEs as patching the old scheme (the barrel shifter
dominates either way: shared reversed shifter, ~200 LEs), and produces the
uop shape the OoO decoder will reuse. Full micro-op decode in ID (A3) was
rejected as premature for the 1-wide baseline.

## D005 — 2026-07-03 — Remove debug_x3 instead of restoring it

The repo shipped with a dangling `debug_x3` connection (see BUGLOG B001).
Options: (a) delete the debug wire from `cpu_pipeline.v`, or (b) restore the
`debug_x3` output port in `register_file.v`. Chose **(a)**: LEDs are driven
through MMIO now, the wire's only consumer was a commented-out debug assign,
and the Verilator testbench will expose full register state anyway — a
hardwired x3 tap is obsolete scaffolding.

## D004 — 2026-07-03 — Repo layout: rtl/{core,mem,soc,top} + tb/sw/synth/docs

Options: flat `src/` (matches the old README) vs. subsystem folders. Chose
subsystem folders because the roadmap (OoO core, NPU, MMIO peripherals) adds
tens of modules; separating "the CPU" (`rtl/core`) from "memories"
(`rtl/mem`) and "the SoC around it" (`rtl/soc`, `rtl/top`) keeps interfaces
honest and makes the eventual `ooo/` and `npu/` additions non-disruptive.
Testbenches live outside `rtl/` so the synthesis file list is exactly
"everything in rtl/".

## D003 — 2026-07-03 — RV32I completion is a stage before CoreMark

The core currently implements ADD/SUB/AND/OR/XOR/SLT, ADDI, LW, SW, BEQ.
Without JAL/JALR (calls), LUI/AUIPC (constants/addressing), shifts, and
byte/half memory ops, no compiled C runs at all. Decision: insert an explicit
"complete RV32I + fix decode bugs" stage between Verilator bring-up and the
CoreMark baseline, done in small increments, each with its own tests, with
microarchitectural choices approved by Hanna.

## D002 — 2026-07-03 — Project home = github.com/hannaashkar/rv32i_cpu

The GitHub repo (uploaded 2025-12-10) is the canonical source going forward;
the local trees `C:\Hanna_Projects\HANNA_CPU` and `Desktop\CleanCPU` remain
untouched as read-only backups. The repo versions were verified
file-by-file against the last known-good local Quartus build: functionally
identical except two fixes (I-type ALUOp, id_ex_reg flush) and one breakage
(B001, fixed in the restructure).

## D001 — 2026-07-03 — Native Windows toolchain instead of WSL

The original plan assumed WSL2, but this machine has no WSL distro
installed. Options: (a) install WSL2 (admin + reboot; Spike easy), (b) native
Windows tools. Hanna chose **(b)**: MSYS2 (make + g++ + Verilator) and xPack
riscv-none-elf-gcc, all user-level installs under `C:\Users\ASUS\tools\`.
Consequence: Spike lockstep co-simulation is deferred (painful to build on
Windows); the golden-model strategy will be revisited when verification
ramps up. Quartus Prime Lite 20.1.1 already lives at `C:\intelfpga_lite\20.1`
on this same machine, so no git-bridge is needed — Quartus opens
`synth/rv32i_cpu.qpf` directly.
