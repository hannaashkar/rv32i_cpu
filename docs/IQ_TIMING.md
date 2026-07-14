# Issue-queue timing rewrite (D028)

> **Historical checkpoint.** D029 has superseded the clock decision and
> current-build metrics below. It proved the memory/load-WB arm of the generic
> EX bypass unreachable, removed that dead mux input without changing a cycle,
> and closed an actual PLL-/2 build at 25 MHz. See
> [WB_BYPASS_TIMING.md](WB_BYPASS_TIMING.md) for the proof, permanent oracle,
> fresh verification, and current Quartus evidence. The D028 measurements in
> this document are intentionally preserved as the before-state.

## Outcome

D027 left one clear timing wall: every top-20 setup path began at `rob_head`,
crossed the issue queue's ALU selection and select-time wakeup logic, and ended
at an IQ operand-ready bit. The worst path was **38.744 ns across 32 logic
levels**, and the complete family came from selecting the oldest ALU, clearing
that winner, and running a second oldest-selection tree for port 1.

D028 replaces that serial **pick → clear → repick** dependency with one
balanced top-two tournament. Each tree node merges two already sorted
`{oldest, second-oldest}` pairs, so the root returns the two oldest eligible
ALU entries together. The visible scheduling result is cycle-exact: there is
no new register, issue stage, dependency bubble, or recovery state.

After place-and-route, the IQ is absent from every top-20 path. Slow-85C Fmax
improves from **25.47 MHz to 27.02 MHz**. The new top-20 family instead runs
from the data-memory M9K read path through load/JALR/redirect logic to a gshare
PHT M9K address, at **36.433–36.132 ns**. A true registered scheduler pipeline
is therefore deferred: it would change issue latency and IPC while no longer
attacking the measured limiter.

## Exact selection contract

The 16-entry IQ still has the same three issue ports:

- port 0 selects the oldest ready control operation, otherwise the oldest
  ready non-CSR ALU operation;
- port 1 selects the oldest ready ALU/CSR operation not already selected by
  port 0;
- port 2 selects the oldest ready memory operation whose store-wait mask is
  clear.

The new `pick2()` tree changes only how port 1 obtains the oldest and
second-oldest ALU candidates. Every leaf starts as a sorted pair containing
one real candidate and one invalid runner-up. Four balanced merge levels
reduce 16 leaves to a single sorted pair. Each `pair_cmb2()` node preserves
the existing modular ROB-age comparison and the existing lower-physical-index
tie break. Port 1 consumes the second result only when port 0 took the first;
otherwise it consumes the first result, exactly as before.

All wakeup, wait-mask, load issue/replay/done, dispatch, branch flush, and full
recovery behavior is unchanged. The public grants remain combinational.

## Independent proof

Three checks cover different failure modes:

1. **INV-I1, live RTL equivalence.** Under Verilator, the former
   pick/one-hot-clear/repick topology remains compiled as an oracle. Every
   cycle it compares the raw oldest result, raw second-oldest result, and the
   port-1 winner actually consumed by the scheduler.
2. **Public-interface golden model.** `make iq-tb` models the 16 resident
   entries without copying the RTL tree. It checks exact modular-age and
   port-class arbitration, all 162 selected payload bits, select-time and
   external-load wakeup, store masks, load replay/done, dual dispatch, branch
   rewind, full flush, and reset behavior.
3. **System lockstep.** Both cores pass 20/20 directed+C, 40/40 rv32ui,
   25/25 base random, 25/25 system/decode-tail random, 25/25 NPU/MMIO random,
   and 80/80 X/reset runs. OoO additionally passes the LQ, SQ, and IQ unit
   models plus 25/25 load-violation stress. Every run is retirement-lockstep
   clean, with zero divergence.

The standalone IQ test passes **300,553 total cycles**, including **300,000
deterministic random cycles**, with **74,571 complete-payload checks** and
**36,515 / 9,816 / 28,240 selections** on ports 0/1/2. Mandatory bins include
occupancy 0–16, dispatch width 0/1/2, every winner leaf on all three ports,
age wrap and tie, all wakeup forms, all eight wait-mask bits, full-IQ select,
replay/done, both flush paths, and reset with live selections.

`hello.c` remains exactly **2,013 cycles / 1,882 retired instructions**.
Reportable 720-iteration CoreMark is also cycle-exact to D027: **506,132,722
benchmark ticks**, **10.122654 s**, **71.127589 iterations/s = 1.422552
CoreMark/MHz**, 506,197,207 full-run cycles, 519,453,600 retired instructions
lockstep-compared, and IPC 1.026. All official CRCs and reportable-validation
checks pass with zero divergence.

Fresh combined line coverage is **99.2% (1522/1534)** across 60 programs per
core with zero test failures. Every D028 IQ addition is covered. The same 12
previously documented defensive/configuration and board-facing MMIO lines
remain uncovered; no exclusions were added to manufacture the percentage.

## Quartus result

Configuration: MAX 10 10M50, complete OoO + NPU + MNIST board top, default
seed, shipping PLL /3 (16.67 MHz).

| Metric | D027 | D028 |
|---|---:|---:|
| Slow-85C Fmax | 25.47 MHz | **27.02 MHz** |
| Analysis & Synthesis LEs | 37,529 | **37,874** |
| Fitted LEs | 34,787 | **35,096 / 49,760 (71%)** |
| Total registers | — | **15,138** |
| Memory bits | 632,444 | **632,444** |
| Multiplier elements | 16 | **16** |
| IQ fitted LCs / registers | 8,270 / 2,720 | **8,565 / 2,720** |

The IQ costs 295 additional fitted LCs and exactly zero new IQ registers. The
area increase buys a shorter combinational topology rather than hidden state.

Slow-85C timing is clean. At PLL /3, setup is **+22.994 ns**,
hold **+0.372 ns**, recovery **+52.869 ns**, and removal **+1.653 ns**. All
timing classes are positive and all five unconstrained-path counts are zero.

## Clock decision and next target

Keep the board at **PLL /3 = 16.67 MHz**. Moving from a 60 ns period to 40 ns
would consume 20 ns of setup slack, leaving a theoretical **+2.994 ns** at
25 MHz. That narrowly misses the predeclared **at least +3 ns** slow-85C gate
(and the preferred +5 ns margin), even though the difference is only
rounding-sized. No PLL /2 claim was made.

After the final RTL text, map and fit were rerun fresh and exactly reproduced
the documented D028 numeric results: 37,874 mapped LEs, 35,096 fitted LEs,
27.02 MHz Fmax, the same slacks, and the same top-20 family. With the checked
MIF program stamp set to `mlp`, `quartus_asm rv32i_cpu` then completed at
22:44:32 with **0 errors / 0 warnings**, producing fresh D028 MNIST `.sof` and
`.pof` files. The full input→map→fit→STA→assembly freshness chain is clean.
These images are **unflashed**: they are build artifacts, not silicon evidence.
Hardware truth remains the earlier 16.67 MHz LED-walker/CFM bring-up; MNIST has
not yet run on the board.

At this D028 checkpoint, the next measured task was D029: shorten the new
load/JALR/redirect/PHT address path. D029 has since completed that work and
promoted the build to PLL /2; see the current-status pointer at the top.
Reconsider a registered IQ scheduler only if a later routed report puts the IQ
back on the wall or broader frequency goals require it.
