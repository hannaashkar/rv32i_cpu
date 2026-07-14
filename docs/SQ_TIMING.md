# Store-queue forwarding timing rewrite (D027)

## Problem

After D026 removed the load-queue violation selector from timing, all 20
slow-85C critical paths crossed the store queue's eight-entry forwarding and
replay scan. The scan visited physical entries in source order while carrying
`found`, best modular age, data, and store width. Quartus implemented that
procedural loop as an eight-deep compare/mux chain inside an already long
load-result → dependent-address → IQ-wakeup path.

The correctness contract is less simple than an ordinary priority encoder:

- only stores strictly older than the querying load are eligible;
- age is a four-bit modular SQ tag measured relative to the current head;
- the **youngest** eligible known store in the same word wins;
- `SW` forwards its full data, while a selected `SB`/`SH` requests replay;
- no match returns zero data;
- `q_older` is independent of address knowledge and matching because device
  loads must wait for every older store to drain.

## Cycle-exact implementation

Each of the eight entries forms these values in parallel:

```text
entry_age = entry_tag - head
load_age  = load_tag  - head
older     = valid && entry_age < load_age
match     = older && known && entry_addr[31:2] == load_addr[31:2]
candidate = {match, entry_age, is_SW, data}
```

A fixed 8→4→2→1 `youngest_of_two` tree chooses the matching candidate with
the larger modular age. Equal ages choose the left/lower-index candidate,
preserving the old ascending scan's strict-`>` behavior. A separate two-level
OR reduction produces `q_older`; it is deliberately not derived from the
forwarding winner.

There is no new register, pipeline stage, or visible latency. The old scan is
compiled only in Verilator as an independent every-cycle oracle and compares
`q_hit`, `q_data`, `q_conflict`, and `q_older` against the tree (INV-S1).
Additional invariants check the queue ring and operation identities rather
than merely checking two implementations of the selector.

## Independent verification

`make sq-tb` drives the module only through its public interface and maintains
an independent C++ lifecycle model. The final D027 run reports:

| Evidence | Result |
|---|---:|
| Total / random cycles | 300,087 / 300,000 |
| Queries | 300,088 |
| Full-word forwards | 45,313 |
| Partial-store conflicts | 90,252 |
| Committed drains | 36,668 |
| Flushes | 2,382 |
| Failures | 0 |

Mandatory bins cover occupancy 0–8, one/two/final-slot allocation, SB/SH/SW,
unknown-store ordering, no-match and multi-match queries, all eight physical
winner leaves, backpressure, commit+drain, branch and full rewind, allocation
coincident with rewind, and pointer wrap. Full-core Verilator gates then run
the oracle and invariants under directed, rv32ui, constrained-random, NPU,
randomized-reset, and load-violation stress. Reportable CoreMark compares
519,453,600 retired instructions with the golden ISA model and is exactly
cycle-identical to D026.

## Physical result

The final MAX 10 board-top compile uses the MNIST program/data MIFs and the
shipping PLL /3 clock:

| Metric | D026 serial scan | D027 tree |
|---|---:|---:|
| SQ mapped combinational LEs | 943 | **924** |
| SQ registers | 596 | **596** |
| SQ fitted logic cells | 1,022 | **1,024** |
| Whole-top fitted LEs | 34,798 | **34,787** |
| Slow-85C Fmax | 25.10 MHz | **25.47 MHz** |
| Setup slack at 16.67 MHz | +20.166 ns | **+20.745 ns** |

The old serial selector is absent from all top-20 timing paths. The small
top-level Fmax gain is not a failed rewrite: it exposes a near-equal path that
was previously hidden. Every new top-20 path starts at `rob_head` and crosses
the issue queue's relative-age, eligibility, selection, and wakeup logic into
`r1`; the worst data delay is 38.744 ns across 32 logic levels.

PLL /2 was rejected by a predeclared margin gate. A 25.47 MHz routed Fmax
implies only about +0.745 ns setup margin at 25 MHz, versus +3 ns minimum and
+5 ns preferred. The current `.sof`/`.pof` therefore remain at 16.67 MHz.

## Engineering takeaway

This increment demonstrates the complete FPGA optimization loop: identify a
path from routed STA, preserve behavior with a live equivalence oracle, add an
independent stateful model and invariants, prove benchmark cycle identity,
refit, and let the new STA—not intuition—choose the next change. The next
measured lever is a true two-stage IQ select/wakeup scheduler; it is an
architectural latency change and must be evaluated with IPC as well as Fmax.
