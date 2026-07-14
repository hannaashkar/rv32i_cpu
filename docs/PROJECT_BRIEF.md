# Measured project brief

## Executive summary

This project develops one RISC-V SoC through measured architectural stages:
a five-stage in-order CPU, a two-wide out-of-order CPU, speculative-load
recovery with store-set prediction, and a tightly coupled 4×4 int8 systolic
NPU. The same freestanding C binaries run on both cores. Every retired
instruction is compared with an independently implemented ISA model, and the
FPGA build has progressed through fitting, timing closure, JTAG bring-up, and
standalone internal-flash boot on a DE10-Lite.

The project deliberately keeps four evidence domains separate: tagged
simulation milestones, current-tree simulation, Quartus fit/STA, and physical
hardware. A built bitstream is never described as hardware-proven until it has
actually run on the board.

## Evidence snapshot

| Domain | Result | Evidence status |
|---|---|---|
| Tagged CPU milestones | 1.177 → 1.397 CoreMark/MHz (**+18.8%**); IPC 0.849 → 1.008 | Reportable, CRC-validated runs at `v1.0-inorder-baseline` and `v2.0-ooo` |
| Current D029 CPU A/B | **1.176568 → 1.422552 CoreMark/MHz (+20.91%)**; IPC 0.849 → 1.026 | Exact same 720-iteration image; OoO: 506,197,207 cycles / 519,453,600 retired instructions, official CRCs and zero lockstep divergence; cycle-exact to D028 |
| Latest NPU A/B | **85.99× / 93.30×** cycle-speedup on in-order / OoO; software and NPU logits bit-exact on **32/32** exported images | D025 cycle-accurate simulation + retirement lockstep |
| Model accuracy | **97.13%** integer accuracy on all 10,000 MNIST test images | Offline integer reference; not presented as a 10,000-image RTL run |
| Verification | 21/21 directed+C, 40/40 `riscv-tests` rv32ui, 25/25 base/sys/NPU random and 84/84 X/reset per core; OoO LQ/SQ/IQ units + 25/25 violation stress; **99.3% RTL line coverage (1596/1607)** | D029 full unit/system/benchmark gates green, zero divergence, 61 coverage programs/core and zero failures |
| Current FPGA build | **34,945 / 49,760 LEs (70%)**, 15,140 registers, 632,444 memory bits, 16 multiplier elements; **31.29 MHz Fmax** | Actual D029 PLL-/2 build closes at **25 MHz** with +8.045 ns slow-85C setup; every timing class positive and zero unconstrained paths |
| Physical hardware | In-order at **50 MHz**; OoO revision at **16.67 MHz** with M9K code and internal-flash boot | DE10-Lite hardware-confirmed with bring-up program |
| MNIST on board | Freshness-clean D029 PLL-/2 `.sof`/`.pof` assembled from MIF stamp `mlp`; unflashed | First physical inference/demo still pending; 25 MHz build artifact is not silicon evidence |

## Architecture

- **In-order CPU:** five stages, forwarding and interlocks, branch prediction,
  RV32I integer compute/load-store/control-flow behavior, Zicsr operations,
  and cycle/instret counters.
- **Out-of-order CPU:** two-wide dispatch/retire, 64-entry physical register
  namespace, 32-entry ROB, 16-entry unified issue queue, 8-entry SQ and LQ,
  gshare/BTB/RAS prediction, speculative-load violation recovery, and a
  store-set memory-dependence predictor.
- **NPU:** 4×4 output-stationary int8 array with 16 int8 MACs, persistent int32
  accumulators, tiled GEMM software, and CPU-enforced device ordering without
  polling.
- **FPGA platform:** M9K-resident instruction and data images, PLL and SDC,
  LED/switch/7-segment MMIO, and MAX 10 internal-flash boot.

## Engineering case studies

### IPC is only half of performance

The first OoO FPGA port improved IPC but reached only 8.42 MHz because the
16-entry issue selection path was a serial priority chain. Replacing it with a
balanced lower-index-preserving tree raised characterized Fmax to 19.65 MHz
(2.33×) without changing a cycle in lockstep simulation. The result is also an
honest negative finding: the hardware-confirmed 16.67 MHz OoO core still loses
wall-clock throughput to the 50 MHz in-order core. D029 now closes a 25 MHz
image, but that image remains unflashed and would still not erase the full
frequency gap. See [DECISIONS.md](DECISIONS.md), D019 and D029.

### A 6R/3W FPGA physical register file

The original 64×32 physical register file consumed 10,947 logic cells as
flops and muxes. D025 implements a live-value-table construction using 18 M9K
banks (six read replicas × three write banks), folded synchronous reads, and
direct/shadow bypasses that reproduce write-first behavior over `OLD_DATA`
memories. It cut the board top by 8,895 LEs, from 88% to 70%, with
cycle-identical benchmark and lockstep behavior. See
[PRF_SHRINK.md](PRF_SHRINK.md).

### Cycle-exact SQ timing repair

D027 replaced the SQ's eight-deep serial youngest-match forwarding/replay scan
with a fixed 8→4→2→1 maximum-age tree. It preserves the exact winner,
partial-store conflict, and older-store semantics; the original scan remains
compiled as a live Verilator oracle. A standalone public-interface golden
model passed 300,087 cycles and 300,088 queries, including 45,313 forwards,
90,252 conflicts, 36,668 drains, 2,382 flushes, every mandatory coverage bin, and
every winner leaf. Quartus kept the SQ state at 596 registers while reducing
mapped combinational logic from 943 to 924; the fitted block is 1,024 LCs. The
old SQ chain disappeared from every top-20 path. Slow-85C Fmax rose to 25.47
MHz, but PLL /2 was rejected because its estimated +0.745 ns setup margin at
25 MHz missed the project's +3 ns sign-off gate. At that D027 checkpoint, the
newly exposed measured limiter was ROB-head-to-IQ port-1 selection/wakeup
(38.744 ns, 32 logic levels); D028 subsequently removed it from the top 20.

### Cycle-exact issue selection repair

D028 follows that evidence without adding a scheduler stage. The old port-1
path selected the oldest ALU, cleared it, then ran a second complete selection
tree. One balanced sorted-pair tournament now returns the oldest two candidates
together. The former topology remains live as a cycle-by-cycle assertion
oracle, while an independent public-interface IQ model passed 300,553 cycles,
74,571 complete 162-bit payload checks, and every winner leaf on all three
ports. `hello.c` remains exactly 2013 cycles / 1882 instructions. Routed Fmax
rose to **27.02 MHz**, and the IQ disappeared from every top-20 path. The new
limiter is a dmem-M9K-read to load/JALR/redirect to gshare-PHT-address family at
36.433–36.132 ns. The more disruptive registered scheduler pipeline is
deferred because it no longer attacks the measured wall. Both-core unit/system
gates and D028's **99.2% (1522/1534)** coverage are green with zero divergence.
Reportable CoreMark is cycle-exact to D027 at **1.422552 CoreMark/MHz, IPC
1.026, 506,197,207 cycles, and 519,453,600 lockstep comparisons**, with
official CRCs. See [IQ_TIMING.md](IQ_TIMING.md).

### A deleted bypass justified by proof, not hope

D029 attacked the next routed wall without adding latency. The old generic EX
operand mux could choose a memory/load result directly from writeback port 2,
but an edge-by-edge pipeline proof showed that an issued dependent cannot reach
EX until the PRF direct/shadow path already holds the same value. This covers
resident and same-edge-dispatched consumers, RAM and SQ-forwarded loads,
MMIO/NPU loads, replay, flush, and tag reuse.

The optimization remains continuously falsifiable: a Verilator-only oracle
shadows the decoder's exact source-use bits by ROB tag, reconstructs the former
bypass priority for every valid EX uop, and stops the run if the deleted arm
would ever win. The new directed test exercises both source inputs on all three
issue ports, load-to-branch/JALR/ALU/store dependencies, both branch outcomes,
and warm/cold indirect control flow. Across reportable CoreMark, **41,073,750
load writebacks** execute while the deleted bypass records **zero uses**.

Behavior is cycle-exact to D028: `hello.c` remains **2,013 cycles / 1,882
instructions**, and reportable CoreMark remains **1.422552 CoreMark/MHz, IPC
1.026, 506,197,207 cycles, and 519,453,600 retired instructions** with the
official CRCs and zero lockstep divergence. Fresh combined coverage rises to
**99.3% (1596/1607)** across 61 programs per core.

The physical result is equally direct: the complete OoO+NPU+MNIST top fits in
**34,945 / 49,760 LEs (70%)**, with 15,140 registers, 632,444 memory bits, and
16 embedded multiplier elements. An actual PLL-/2 build reaches **31.29 MHz
Fmax** and closes at **25 MHz** with **+8.045 ns** slow-85C setup slack. Hold,
recovery, and removal are also positive, and there are zero unconstrained
paths. That is a **50% configured-clock increase** without losing one
benchmark cycle. Fresh MLP
`.sof` and `.pof` files were assembled, but remain unflashed. Hardware truth is
still the earlier 16.67 MHz LED-walker/CFM bring-up. See
[WB_BYPASS_TIMING.md](WB_BYPASS_TIMING.md).

### Recovery stress found a non-obvious stale-uop bug

A load-order violation reused the branch-flush age predicate with a synthetic
six-bit tag of `head-1`. The intended comparison effectively asked whether a
six-bit age was greater than 63, so the issue queue cleared zero entries and
stale uops could reissue after physical registers were recycled. The rv32ui
`ld_st` test exposed B013 at the exact retiring instruction; a dedicated
violation-random lane now makes the recovery path fire 1,185 times. See
[BUGLOG.md](BUGLOG.md), B013.

### CPU/NPU ordering is enforced in hardware

Software does not poll the NPU. The in-order core snapshots forwarded operands
while holding a busy device access in EX; the OoO core replays device loads
until older stores drain and the NPU is idle. That contract lets the ISS model
each GO atomically while remaining architecturally exact. Directed and random
tests permanently guard the two bugs found in this path (B010/B011). See
[NPU.md](NPU.md).

## Reproduce the evidence

From PowerShell, use the native wrapper shown below. GNU Make users can drop
the `scripts\make.cmd` prefix.

```powershell
scripts\make.cmd verify
scripts\make.cmd verify-ooo
scripts\make.cmd coverage
scripts\make.cmd iq-tb
scripts\make.cmd coremark
scripts\make.cmd coremark-ooo
scripts\make.cmd coremark-compare
scripts\make.cmd npu-mlp
scripts\make.cmd npu-mlp-ooo
```

The current `coremark` targets require CoreMark's own `Correct operation
validated` result; `coremark-ooo` defaults to 720 iterations because the
faster core completes 600 iterations in less than the reportable 10-second
benchmark window. Use `coremark-quick` / `coremark-quick-ooo` only for short
CRC correctness checks. `coremark-compare` builds one 720-iteration image,
runs that exact image on both cores, and preserves `coremark-inorder.log` and
`coremark-ooo.log` separately.

The 2026-07-14 same-image control measured **58.828385 iterations/s** on the
in-order core and **71.127589 iterations/s** on the D029 OoO core at the common
50 MHz reporting reference: 1.176568 versus 1.422552 CoreMark/MHz. Both runs
printed `Correct operation validated` and matched all official 2K CRCs. The
OoO run completed 720 iterations in 10.122654 seconds from 506,132,722
benchmark ticks; the full harness measured 506,197,207 cycles and 519,453,600
retired instructions with no lockstep divergence. D029 is cycle-exact to D028
(which is cycle-exact to D027 and D026) on this benchmark.

The historical +18.8% comparison belongs to the tagged milestone. At
`v2.0-ooo`, reproduce it with `make verify-ooo && make coremark-ooo
CM_ITER=720`; the baseline method and exact run context are in
[BASELINE.md](BASELINE.md) and [OOO.md](OOO.md).

## Scope and limitations

- ECALL/EBREAK do not trap. Privileged modes, interrupts, precise exceptions,
  RV32M/A, `fence.i`, an MMU, caches, and an SDRAM controller are outside the
  current implementation. This is not a Linux-capable platform.
- The 40/40 result is the integer `riscv-tests` rv32ui suite, not a full
  privileged/compliance certification.
- 99.3% (1596/1607 on D029) is combined Verilator RTL **line** coverage, not
  functional or formal coverage. The proof oracle and all six load-consumer
  operand bins are covered; 11 documented lines remain uncovered.
- NPU speedups are hardware-counter measurements in cycle-accurate RTL
  simulation. The full-dataset 97.13% result is the offline integer model;
  the on-core comparison covers 32 exported images, and the board image embeds
  eight.
- Fresh D029 MNIST `.sof`/`.pof` files have routed, complete merge-gate, and
  input-to-assembly freshness evidence. They remain unflashed, so they have no
  physical-demo evidence. The older OoO bring-up image
  proved fetch, timing, and CFM boot
  on silicon with the LED walker; it did not exercise NPU inference.
- D026–D029 removed the LQ, SQ, IQ-repick, and dead memory-writeback bypass
  chains from the measured timing wall. D029 reaches **31.29 MHz** slow-85C
  Fmax and closes an actual 25 MHz PLL-/2 build with +8.045 ns setup slack.
  The new top-20 family is ROB-head-to-IQ operand readiness. The physical board
  remains confirmed only at 16.67 MHz until the 25 MHz image is flashed.

## Evidence index

- Baseline measurement: [BASELINE.md](BASELINE.md)
- Tagged OoO milestone: [OOO.md](OOO.md)
- Current NPU measurements and validation scope: [NPU.md](NPU.md)
- Verification lanes and line coverage: [VERIFICATION.md](VERIFICATION.md)
- PRF implementation and Quartus result: [PRF_SHRINK.md](PRF_SHRINK.md)
- SQ timing rewrite and proof: [SQ_TIMING.md](SQ_TIMING.md)
- IQ timing rewrite and proof: [IQ_TIMING.md](IQ_TIMING.md)
- Load-writeback bypass proof and 25 MHz build: [WB_BYPASS_TIMING.md](WB_BYPASS_TIMING.md)
- Board acceptance state: [DEMO.md](DEMO.md)
- Architectural decisions: [DECISIONS.md](DECISIONS.md)
- Root-caused bugs: [BUGLOG.md](BUGLOG.md)
