# Issue-queue wakeup retiming (D030)

## Status

Architecture decision locked on 2026-07-15. RTL implementation and production
sign-off are in progress on `codex/iq-wakeup-retime`. The numbers in the
acceptance section are gates, not achieved results. This document will be
updated with measured verification and Quartus evidence before merge.

## Measured problem

D029's routed top reaches 31.29 MHz, but all top-20 slow-85C setup paths are
now one issue-queue family. The worst path is 31.517 ns across 26 logic levels:

```
ROB head -> modular age -> winner selection -> selected destination tag
         -> wakeup compare -> IQ source-ready bit
```

The final selected-tag compare and ready-bit write costs roughly 5 ns after
the scheduler has already done its oldest-ready selection. That is a feedback
path through the issue queue: a grant made this cycle directly changes the
queue's ready state at the same edge.

## Decision

Capture the three wake events in small registers, then use those captured tags
as the next cycle's ready bypass. The events are:

- port 0 select-time destination tag;
- port 1 select-time destination tag;
- successful load-completion/EX-success destination tag.

Each event is one valid bit plus one 6-bit physical-register tag. The change
adds 21 state bits. It does not register public grants, add an issue stage, or
change the RF/EX pipeline.

Three options were considered:

1. Register all issue grants. This gives a hard timing cut, but adds scheduler
   latency, changes dependent spacing, and requires wider flush/replay changes.
2. Split the IQ payload into separate scheduling and execution storage. This
   remains a useful area step, but a true 2-write/3-read FPGA implementation
   needs replication/LVT machinery and does not directly remove the measured
   selected-destination wakeup feedback.
3. Register only the wake events and bypass the registered tags into next-
   cycle eligibility. This attacks the measured final cone and can preserve
   the D029 schedule cycle for cycle.

Option 3 is D030.

## Cycle-exact contract

Let cycle N end at edge E(N).

In D029, a producer selected during cycle N broadcasts its destination tag.
At E(N), a matching resident source-ready bit becomes 1. The dependent can
therefore be selected during cycle N+1.

In D030, E(N) captures that same broadcast into a wake register. During cycle
N+1, effective readiness is:

```
effective_r1 = stored_r1 || captured_wake_matches(ps1)
effective_r2 = stored_r2 || captured_wake_matches(ps2)
```

The dependent is therefore selectable in the same cycle N+1. At E(N+1), the
captured match is persisted into the stored ready bit while the wake register
captures the next event. There is no producer-consumer bubble.

The same rule covers a uop dispatched at E(N). Dispatch stores only readiness
from the busy table (plus the existing unused-source/x0 rules); a slot-1 source
produced by slot 0 remains forced unready. During its first resident cycle, the
wake captured at E(N) supplies the same next-cycle readiness that D029 stored
directly during dispatch. Removing the current-grant/current-load arms from
`ooo_cpu.rdy_now()` is part of D030; otherwise an alternate feedback path
would still end at the IQ dispatch-ready flops.

## Dispatch and recovery rule

Dispatch must not OR either current or captured wake tags into permanent ready
state. It stores only `disp_r1` and `disp_r2`. This is important after a branch
or full flush: a killed producer's captured tag may remain for one cycle, and
a newly allocated physical tag must never inherit that stale event.

This does not lose a legal same-edge dispatch wake. The newly dispatched entry
is not resident until after the edge; in its first resident cycle it sees the
tag just captured at that edge. At the following edge, the match is persisted.

Recovery behavior remains:

- branch flush kills strictly younger resident entries and same-edge dispatch;
- full violation recovery clears every resident entry;
- reset clears all wake valid bits asynchronously;
- a captured tag is only a one-cycle bypass hint and never changes validity,
  issue state, masks, replay state, or physical-register ownership.

## Permanent proof structure

D030 uses three independent checks:

1. **Legacy readiness shadow.** In Verilator, a simulation-only shadow keeps
   the D029 ready-state update rule using current-cycle wakes. For every live
   entry and both sources, it must equal D030's stored-ready OR captured-wake
   effective readiness on every cycle.
2. **Old scheduler and public golden model.** D028's old pick/clear/repick
   selection oracle remains live. The standalone IQ model remains written in
   terms of D029's architectural select-time-wakeup contract and compares all
   162 bits of every selected payload.
3. **System retirement lockstep.** Directed, ISA, random, X/reset, NPU/MMIO,
   and load-violation runs compare every retired instruction against the ISS.

Directed IQ cases must cover both operands, all three wake sources, dual
internal broadcasts, same-edge dispatch, load replay, branch flush, full
flush, reset, and stale-tag reuse after recovery.

## Predeclared acceptance gates

D030 may merge to production only if all of these pass:

- standalone IQ model: at least 300,000 random cycles plus all mandatory
  directed bins, with zero mismatches;
- exact selected indices and full selected payloads versus the legacy model;
- legacy effective readiness equality for every live entry/source every cycle;
- both cores pass all directed/C, 40/40 rv32ui, base/system/NPU random, and
  randomized-X/reset suites; OoO also passes violation stress;
- all system runs remain retirement-lockstep clean;
- combined line coverage is at least D029's 99.3%, with no new uncovered D030
  logic;
- `hello.c` remains exactly 2,013 cycles / 1,882 retired instructions;
- reportable CoreMark remains exactly 506,197,207 full-run cycles and
  519,453,600 retired instructions, with 1.422552 CoreMark/MHz and all official
  CRC checks passing;
- fresh full-top Quartus fit is at most 1% larger in fitted LEs;
- slow-85C Fmax is at least 34.4 MHz, a 10% improvement over D029's 31.29 MHz;
- no same-cycle grant-to-IQ-ready path remains in the top 100 setup paths;
- setup, hold, recovery, and removal are positive at every analyzed corner,
  with zero unconstrained paths.

The board clock stays at the already shipping-build value of 25 MHz unless a
different PLL setting has at least +3 ns slow-85C setup margin after a real
fit. A faster build is still not a silicon claim until Hanna flashes and runs
it on the DE10-Lite.

## Expected result and successor work

The measured final feedback cone is about 5 ns, so the expected routed range
is roughly 34-38 MHz with about 21 new registers and no new M9Ks. This is a
forecast, not a result.

D030 is deliberately scoped to IQ source readiness. Current grants still
clear the core's global `busy[]` physical-register scoreboard at the select
edge. That path was not in D029's top 20, but it may become a later timing wall;
the D030 top-100 report must describe it honestly rather than claiming that all
grant-to-readiness feedback disappeared.

After D030, the planned high-value milestones are:

1. module-level SymbiYosys proofs around IQ/LQ/SQ/PRF/fetch control once a
   formal toolchain is installed; and
2. precise machine-mode traps, a timer and UART, then a small RTOS workload
   with measured interrupt latency and an NPU worker.

Linux remains later. The current core does not yet have the privilege modes,
virtual memory, atomics, caches, SDRAM controller, firmware handoff, timer, or
UART required for an honest Linux-capable claim.
