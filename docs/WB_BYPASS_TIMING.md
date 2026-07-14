# Load-writeback bypass timing cut (D029)

## Outcome

D028 removed the issue queue from the timing wall. Its new top-20 setup paths
all began at the synchronous data-memory result, crossed the generic EX
operand bypass, JALR target/redirect logic, and ended in the branch predictor.
The worst path was **36.433 ns**. The third arm of the bypass mux selected the
memory-port result (`wb_result2`) when WB2's destination physical register
matched an EX source.

D029 proves that this WB2 arm cannot win for a consumed operand in the current
pipeline, removes only that arm, and keeps the two ALU-result bypass arms. No
pipeline register, wakeup rule, load latency, issue rule, recovery state, or
architectural behavior changes. `hello.c` and CoreMark remain cycle-exact.

The cut removes the complete dmem -> generic bypass -> JALR/redirect ->
predictor family from the routed top 20. A conservative PLL-/3 characterization
reaches **29.14 MHz**. That cleared the project's predeclared margin gate, so a
real PLL-/2 build was then placed, routed, and analyzed at **25 MHz**. It passes
slow-85C timing with **+8.045 ns setup slack** and reports **31.29 MHz Fmax**.
This is a verified build-time clock increase from 16.67 MHz to 25 MHz, or
**50%**, without an IPC change.

## Why removal was the right option

Four options were evaluated against the measured D028 path:

1. **Declare the path false.** Rejected. Loads and their JALR/branch/ALU/store
   consumers are legal operations. A false-path constraint would hide real
   logic from STA without shortening it, and would turn the timing report into
   fiction.
2. **Delay load dependants by another cycle.** This makes the overlap disappear
   by construction, but adds a load-use bubble and gives away performance on
   every dependent load. It also changes the verified scheduling contract to
   solve a mux input that is already unreachable.
3. **Register or pipeline the load/redirect path.** A new EX/redirect stage is
   a strong future frequency lever, but it changes branch resolution latency,
   mispredict recovery, predictor training alignment, and IPC. It is broader
   than the measured problem.
4. **Remove only the WB2 arm after proving it dead.** This cuts the measured
   cone while preserving the current cycle contract. The WB0 and WB1 ALU arms
   stay because same-cycle ALU wakeup can place a dependent in EX while its
   producer is still in WB.

Option 4 was selected. The change is an implementation optimization backed by
a pipeline proof, a permanent RTL oracle, directed positive coverage, full
lockstep regression, and routed timing.

## Exact edge proof

A successful load executes on memory port 2. Replay is already known in EX, so
`wb_v2_isload_wr` broadcasts its destination tag to the IQ only when the load
really completes. The following table shows the earliest possible dependent:

| Edge / interval | Load | Earliest dependent | Value path |
|---|---|---|---|
| Before E1 | Successful in EX; replay decision is known | Resident or same-edge-dispatched consumer is not yet selectable | Load-success wake is asserted |
| E1 | Captured into WB2 | IQ records the wake; the consumer becomes ready | WB2 now drives the PRF write port |
| E1 to E2 | In WB2 | Consumer can be selected, but is only in SEL | Source tags drive the PRF's registered read addresses |
| E2 | WB2 write commits to the PRF | Consumer enters RF | PRF captures the write in its one-cycle shadow while the M9K may return OLD_DATA |
| E2 to E3 | Load has left WB2 | Consumer is in RF | PRF shadow supplies the exact load value |
| E3 | No longer in WB2 | Consumer first enters EX | EX captures the correct PRF value; a WB2 bypass match is impossible |

The key inequality is therefore simple: **load WB2 ends before dependent EX
begins**. A consumer selected later is even farther from the load's WB cycle;
the PRF shadow or bank supplies it. A consumer already resident in the IQ and
a consumer dispatched on the wake edge share the same earliest selection edge,
so neither creates a shorter case.

The proof applies to every WB2 load source:

- synchronous RAM reads;
- full-word SQ forwarding;
- MMIO reads;
- NPU reads.

They differ in how `wb_result2` is produced, not in wake, SEL, RF, PRF-write,
or EX timing. A replayed load asserts neither the successful wake nor a valid
WB write, so it cannot violate the proof. Branch recovery and violation
recovery may kill work, but do not skip the RF stage. The oracle checks all
valid EX uops, including uops killed on that edge, so correctness does not rely
on a squash hiding a timing case. Full ROB tags protect the source-use shadow
against physical-slot reuse.

## Permanent proof oracle

The Verilator build retains two D029 invariants and positive-coverage counters:

- **INV-B0** carries the decoder's authoritative `rs1_used` and `rs2_used`
  bits in a Verilator-only, full-ROB-tagged shadow. At EX it proves that the
  shadow belongs to the exact uop being checked. This avoids false reasoning
  about immediate, LUI/AUIPC, CSR-immediate, x0, and NOP-class operands.
- **INV-B1** models the exact priority of the old bypass mux: WB0 first, WB1
  second, WB2 last. It checks both truly consumed sources on every valid EX
  port, including same-cycle-killed uops, and fatals if the old WB2 arm would
  have won.
- Counters record successful load writebacks, WB2-tag matches while dependants
  are in SEL, all six `{port 0/1/2} x {source A/B}` bins, consumed EX operands,
  live WB0/WB1 hits, and old-WB2 hits. The SEL matches are important positive
  evidence: tests reach the exact cycle immediately before the alleged EX
  hazard rather than passing because no load dependence was generated.

The oracle remains in the source permanently. If a future scheduler, PRF, or
pipeline change makes the removed path necessary, simulation stops at the
first counterexample instead of silently corrupting data.

## Directed test

`sw/tests/load_wb_bypass.S` contains 24 self-checks and forces RAM loads (not
SQ-forwarded setup values) by draining setup stores through a strongly ordered
MMIO read. Critical load/consumer pairs are aligned for two-wide dispatch. It
checks:

- JALR bit-0 clearing and positive/negative immediates;
- a loaded return address;
- cold and warm indirect calls whose target starts with a taken branch;
- all six RV32I branch conditions, both taken and not taken, with the loaded
  value alternating between source A and source B;
- two simultaneous ALU consumers arranged to hit p0a, p0b, p1a, and p1b;
- load-to-store address and load-to-store data on memory port 2.

The focused OoO run passes in **389 measured cycles / 177 retired
instructions / 177 lockstep comparisons**. The oracle reports **26 successful
load writebacks, 26 WB2-tagged SEL targets, `sel_seen=3f` (all six bins), 287
consumed EX operands, 27 real WB0/WB1 hits, and 0 WB2 hits**. The in-order twin
passes in 276 measured cycles / 174 retired instructions / 175 comparisons.

All four OoO load policies also pass the directed case: conservative policy 0
in 320 harness cycles, and always-speculate, shipping store-set, and Alpha-style
policies 1/2/3 in 388 harness cycles. Every policy reaches `sel_seen=3f` and
reports zero WB2 EX hits.

## Full verification

The final post-cut verification matrix is green:

| Gate | Result |
|---|---|
| PRF public-interface model | PASS, 300,014 ticks, 0 failures |
| LQ public-interface model | PASS, 250,026 cycles, 218,731 probes, 55,318 hits |
| SQ public-interface model | PASS, 300,087 cycles, 300,088 queries, 45,313 forwards, 90,252 conflicts, 36,668 drains, 2,382 flushes |
| IQ public-interface model | PASS, 300,553 cycles, 74,571 payload checks, 36,515 / 9,816 / 28,240 port selections |
| In-order system | 21/21 directed+C, 40/40 rv32ui, 25/25 base random, 25/25 system/decode-tail random, 25/25 NPU/MMIO random, 84/84 randomized-X/reset |
| OoO system | Same complete matrix plus 25/25 load-violation stress; every run retirement-lockstep clean |
| Alternate load policies | Policies 0, 1, and 3 spot-regressed in addition to shipping policy 2 |

The randomized-X/reset total uses four independent seeds. No D029 invariant
fired and no lockstep divergence occurred.

Fresh combined line coverage is **99.3% (1596/1607)** across **61 programs per
core**, with zero test failures. The 11 uncovered lines are existing defensive,
configuration-only, or board-facing cases; no exclusion was added to inflate
the result.

## Cycle-exact performance

`hello.c` remains exactly **2,013 cycles / 1,882 retired instructions**, IPC
0.935, with 1,883 lockstep comparisons and zero divergence.

The reportable 720-iteration CoreMark run is also exactly unchanged from D028:

- benchmark ticks: **506,132,722**;
- benchmark time: **10.122654 s**;
- rate: **71.127589 iterations/s = 1.422552 CoreMark/MHz**;
- full-run cycles: **506,197,207**;
- retired instructions and lockstep comparisons: **519,453,600**;
- IPC: **1.026**;
- CRCs: seed `e9f5`, list `e714`, matrix `1fd7`, state `8e3a`, final `a14c`;
- `Correct operation validated`, reportable-rules validation passed, zero
  divergence.

The printed seconds and iterations/second use the port's fixed **50 MHz
reporting reference** so the same image can be compared directly with the
baseline. They are not a measured 25 MHz board rate. At the configured board
clock, the cycle-equivalent expectation is about **35.56 iterations/s**;
`CoreMark/MHz` is the clock-normalized comparison used here.

Across CoreMark, the permanent oracle observes **41,073,750 load writebacks,
47,050,722 WB2-tagged SEL targets, all six SEL bins, 760,546,213 consumed EX
operands, 179,766,342 WB0/WB1 hits, and exactly 0 WB2 hits**. This large dynamic
sample reinforces the edge proof without replacing it.

## Quartus characterization and clock decision

Both builds use Quartus Prime Lite 20.1.1, the MAX 10 10M50DAF484C7G, the
complete OoO + NPU + MNIST board top, final timing models, and the default
seed.

| Metric | D028 PLL /3 | D029 PLL /3 characterization | D029 actual PLL /2 build |
|---|---:|---:|---:|
| CPU clock | 16.67 MHz | 16.67 MHz | **25.00 MHz** |
| Slow-85C Fmax | 27.02 MHz | **29.14 MHz** | **31.29 MHz** |
| Analysis & Synthesis LEs | 37,874 | **37,676** | **37,688** |
| Fitted LEs | 35,096 | **34,886 / 49,760 (70%)** | **34,945 / 49,760 (70%)** |
| Total registers | 15,138 | **15,140** | **15,140** |
| Memory bits | 632,444 | **632,444** | **632,444** |
| Multiplier elements | 16 | **16** | **16** |
| Slow-85C setup slack | +22.994 ns | **+25.678 ns** | **+8.045 ns** |
| Slow-85C hold slack | +0.372 ns | **+0.397 ns** | **+0.339 ns** |
| Slow-85C recovery slack | +52.869 ns | **+52.039 ns** | **+34.440 ns** |
| Slow-85C removal slack | +1.653 ns | **+1.583 ns** | **+1.506 ns** |

At /3, the projected /2 setup margin was +5.678 ns, clearing the required
`>=3 ns` and preferred `>=5 ns` trial gates. D029 therefore changed the PLL to
/2 and performed a real new map, fit, and STA run rather than claiming the
projection alone.

At the actual 25 MHz clock, every timing class is positive at all three
analyzed corners. Slow-0C setup/hold/recovery/removal are **+10.448 / +0.293 /
+34.892 / +1.323 ns**; fast-0C values are **+26.222 / +0.168 / +37.266 /
+0.698 ns**. All five unconstrained-path counts are zero.

The /3 top-20 family starts at the RF/uop M9K and ends in branch/JALR
BTB-training state, with a 33.974 ns worst data delay. In the actual /2 route,
all top-20 paths instead run from `rob_head` into IQ operand-ready state; the
worst data delay is **31.517 ns**. The old dmem/WB2 bypass family is absent.
This makes any later frequency work evidence-driven again: the next target is
ROB-age/IQ readiness, not load result forwarding.

## Fresh FPGA images and hardware truth

With the MIF program stamp set to `mlp`, final map, fit, STA, and assembly all
completed successfully. Assembly finished with 0 errors and 0 warnings. The
fresh 25 MHz files are:

- `rv32i_cpu.sof`, 3,216,563 bytes, SHA-256
  `1ECB4B6D8E450587CC6F96C13D3008CDC90CE1DED64137D8C82B6786DE14E85D`;
- `rv32i_cpu.pof`, 1,450,248 bytes, SHA-256
  `C2F40218950DE037BF214ABEBA6A83392F81744E10D627043C96CF7414439C75`.

These hashes identify build artifacts, not a hardware result. The D029 25 MHz
MNIST image has **not yet been flashed**. The latest silicon-confirmed truth is
the earlier OoO LED walker and standalone CFM boot at **16.67 MHz**. Hardware
acceptance at 25 MHz, followed by the MNIST board demo, remains the next
physical step.
