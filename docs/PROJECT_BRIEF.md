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
| Current D026 CPU A/B | **1.176568 → 1.422552 CoreMark/MHz (+20.91%)**; IPC 0.849 → 1.026 | Exact same 720-iteration image; two reportable runs; ~519.45M instructions lockstep-checked per core |
| Latest NPU A/B | **85.99× / 93.30×** cycle-speedup on in-order / OoO; software and NPU logits bit-exact on **32/32** exported images | D025 cycle-accurate simulation + retirement lockstep |
| Model accuracy | **97.13%** integer accuracy on all 10,000 MNIST test images | Offline integer reference; not presented as a 10,000-image RTL run |
| Verification | 40/40 `riscv-tests` rv32ui; **99.2% RTL line coverage (1449/1461)**; 15 documented RTL/SoC integration bugs | Both cores, reproducible seeded lanes |
| Current FPGA build | **34,798 / 49,760 LEs (70%)**, 95/182 M9Ks, 16 multipliers; **25.10 MHz Fmax**, +20.166 ns at 16.67 MHz | Quartus fitter + slow-85C STA, D026 |
| Physical hardware | In-order at **50 MHz**; OoO revision at **16.67 MHz** with M9K code and internal-flash boot | DE10-Lite hardware-confirmed with bring-up program |
| MNIST on board | Current `.sof` built and timing-clean | First physical inference/demo still pending |

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
honest negative finding: at 16.67 MHz, the OoO core still loses wall-clock
throughput to the 50 MHz in-order core. See [DECISIONS.md](DECISIONS.md), D019.

### A 6R/3W FPGA physical register file

The original 64×32 physical register file consumed 10,947 logic cells as
flops and muxes. D025 implements a live-value-table construction using 18 M9K
banks (six read replicas × three write banks), folded synchronous reads, and
direct/shadow bypasses that reproduce write-first behavior over `OLD_DATA`
memories. It cut the board top by 8,895 LEs, from 88% to 70%, with
cycle-identical benchmark and lockstep behavior. See
[PRF_SHRINK.md](PRF_SHRINK.md).

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
in-order core and **71.127589 iterations/s** on the D026 OoO core at the common
50 MHz reporting reference: 1.176568 versus 1.422552 CoreMark/MHz. Both runs
printed `Correct operation validated`, matched all official 2K CRCs, and
compared about 519.45 million retired instructions with no lockstep divergence.

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
- 99.2% is combined Verilator RTL **line** coverage, not functional or formal
  coverage.
- NPU speedups are hardware-counter measurements in cycle-accurate RTL
  simulation. The full-dataset 97.13% result is the offline integer model;
  the on-core comparison covers 32 exported images, and the board image embeds
  eight.
- The latest D026 MNIST bitstream has fit/STA evidence but no physical-demo
  evidence yet. The older OoO bring-up image proved fetch, timing, and boot on
  silicon with the LED walker; it did not exercise NPU inference.
- D026 raised slow-85C Fmax from 23.51 to **25.10 MHz** and removed the LQ
  selector from every top-20 path. The new measured limiter is the load result
  through a dependent memory AGU and the SQ's serial youngest-match
  forwarding/replay scan into IQ load wakeup. The board remains at 16.67 MHz;
  the ~0.17 ns theoretical margin at 25 MHz is too narrow for a PLL /2 sign-off.

## Evidence index

- Baseline measurement: [BASELINE.md](BASELINE.md)
- Tagged OoO milestone: [OOO.md](OOO.md)
- Current NPU measurements and validation scope: [NPU.md](NPU.md)
- Verification lanes and line coverage: [VERIFICATION.md](VERIFICATION.md)
- PRF implementation and Quartus result: [PRF_SHRINK.md](PRF_SHRINK.md)
- Board acceptance state: [DEMO.md](DEMO.md)
- Architectural decisions: [DECISIONS.md](DECISIONS.md)
- Root-caused bugs: [BUGLOG.md](BUGLOG.md)
