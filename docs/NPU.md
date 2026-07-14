# NPU — 4×4 int8 output-stationary systolic array (decision D014)

Binding spec for `rtl/npu/`. The NPU is a tightly-coupled matmul
accelerator hanging off the memory port of BOTH cores at MMIO region
`0x5xxx_xxxx`, mirrored instruction-exactly by the lockstep golden model
(`tb/verilator/iss.h`) so every program that touches it is co-simulated.

## What it computes

One **GO** command streams one 4×4×4 tile through the array:

```
C[i][j] += sum_k A[i][k] * B[k][j]      i,j,k in 0..3, A,B int8, C int32
```

C is **output-stationary**: the 16 accumulators live inside the PEs and
persist across GO commands, so a large-K matmul is a chain of GOs over
k-tiles (`CLR` on the first, plain `GO` after) with C read back once.
Larger M/N are handled by software tiling (see the driver mapping below).

## Register map (word access ONLY — LW/SW, aligned)

| addr        | name    | R/W | contents                                    |
|-------------|---------|-----|---------------------------------------------|
| 0x5000_0000 | NPU_ID  | R   | constant 0x4E505501 ("NPU", version 1)      |
| 0x5000_0004 | STATUS  | R   | bit0 = busy, bit1 = done                    |
| 0x5000_0008 | CTRL    | W   | bit0 = GO, bit1 = CLR (clear accumulators)  |
| 0x5000_0010 | A0..A3  | RW  | +i*4: row i of A, byte k = A[i][k] (int8)   |
| 0x5000_0020 | B0..B3  | RW  | +k*4: row k of B, byte j = B[k][j] (int8)   |
| 0x5000_0040 | C0..C15 | R   | +n*4: accumulator C[n/4][n%4], int32        |

Semantics:
* `CTRL.CLR` zeroes all 16 accumulators and the `done` flag. `CTRL.GO`
  starts a 10-cycle tile pass; `done` is set when it completes.
  `GO|CLR` in one store = clear, then run (the usual first-k-tile write).
  A CTRL store with neither bit is a no-op.
* Reads are **side-effect-free** (safe under speculative/wrong-path
  execution in the OoO core). Writes to read-only addresses are dropped;
  unmapped reads return 0.
* Address decode is exact (all 32 bits): misaligned or sub-word accesses
  hit the "unmapped" case. Like the 0x4 MMIO region, loads return the raw
  register word (no byte-lane extraction) and stores write the full rs2
  word regardless of funct3 — use `volatile uint32_t` accesses only.

## Microarchitecture (rtl/npu/)

* `npu_pe.v` — one processing element: registered `a`/`b` pass-through
  (west→east, north→south) and a 32-bit accumulator that adds the int8×int8
  product of its *inputs* each run cycle. 8×8 signed multiply maps to a
  MAX 10 embedded 9×9 multiplier.
* `npu_array.v` — the 4×4 PE grid plus skew feeders and the run FSM.
  With classic systolic skew, PE(i,j) sees `A[i][t-i-j]` from the west and
  `B[t-i-j][j]` from the north during run cycle `t`, accumulating exactly
  the k=t-i-j product term. The last term (k=3 at PE(3,3)) flows at t=9,
  so one pass = **10 run cycles**, cnt 0..9. Feeders inject zeros outside
  a lane's live window — zero products, no accumulator pollution.
* `npu_top.v` — MMIO front end: A/B staging registers, CTRL/STATUS/ID
  decode, read mux over the flattened 512-bit accumulator bus, and the
  `busy` / `busy_next` interlock exports (`busy_next` also covers a GO
  arriving this cycle, closing the 1-cycle busy-register gap).

## Memory-ordering interlocks (the important part)

The NPU's registers are device state; program-order semantics must hold
even though the OoO core executes loads speculatively and drains stores
from the SQ several cycles after retirement. The invariant both cores
enforce in hardware:

> **An NPU access performs only when every older store has reached the
> device and the array is idle.** Software never polls; the hardware
> interlock makes `STATUS.busy` unobservable (it always reads 0), which
> is also exactly what makes the instantaneous ISS model lockstep-exact.

* **OoO core** (`ooo_cpu.v`):
  - *IO loads replay until ordered.* A load whose address decodes to an IO
    region (0x4 or 0x5) replays (existing IQ replay path, oldest-first
    select ⇒ no livelock) while ANY older store is still in the SQ, and —
    for the NPU region — while `busy_next` is set. When it finally
    performs, all older stores have drained, so an SQ forwarding hit is
    impossible by construction (asserted in sim). This also fixes latent
    bug B010 (SQ forwarding used to shadow MMIO reads).
  - *SQ drain backpressure.* The SQ head does not drain into a busy NPU:
    `mw_ready = !(mw_isnpu && npu_busy)` holds the (already committed)
    store until the pass completes; dmem/mmio stores are never held.
    Store buffering is bounded (SQ=8) and busy self-clears in 10 cycles,
    so dispatch stalls at worst briefly — no deadlock cycle exists.
* **In-order core** (`cpu_pipeline.v`):
  - An NPU access **stalls in EX** while `npu_busy_next` is set: PC, IF/ID
    and ID/EX freeze (ID/EX gains a `stall` input that wins over `flush`),
    and EX/MEM receives bubbles. Nothing at MEM/WB freezes, so no side
    effect can repeat. `busy_next` covers the back-to-back case where the
    GO store is still in MEM when its dependent access sits in EX.
  - The held access's address and store data are **snapshotted on the
    first stall cycle** (B011): because MEM/WB drain during the hold, the
    live forwarding muxes decay to stale decode-time operands — the
    snapshot (taken while forwarding is still valid by construction) is
    what the stall decision and the eventual EX/MEM latch use. An
    assertion enforces that a hold only ever releases because the array
    went idle. Directed test: `sw/tests/npu_ordering.S`.
  - Stores are naturally ordered (single MEM stage, program order).

## Golden-model mirror (iss.h)

The ISS executes the NPU **instantaneously at the store that carries GO**
(program order). Because of the interlocks above, RTL software can only
ever observe post-completion state, so instantaneous-vs-10-cycles is
invisible — every NPU register read and every NPU store is lockstep-
compared like ordinary architectural state. `done` mirrors exactly
(GO ⇒ 1 at completion, CLR ⇒ 0); `busy` reads 0 on both sides.

## Software mapping (sw/common/npu.h, sw/npu_mlp/)

Tiled GEMM `C[M][N] = A[M][K] × B[K][N]`, all dims padded to multiples
of 4: for each 4×4 output tile, `CTRL=GO|CLR` on the first k-tile then
`GO` per remaining k-tile (4 A-word stores + 4 B-word stores + 1 CTRL
store each), then 16 C loads. Cost per k-tile ≈ 9 stores + loop overhead
for 64 MACs — versus 64 software MACs at ~35 cycles each (`__mulsi3`;
rv32i has no hardware multiply), which is what makes the measured
speedup large.

(Known limitation, logged in the BUGLOG watch list: OoO IO loads are not
age-ordered against older IO *loads* — irrelevant for the NPU, whose
registers only change via this hart's own stores, but noted for
externally-mutable MMIO like the switches until the LQ stage.)

MNIST MLP (784→32→10, decision D015): int8 symmetric per-tensor weights,
inputs quantized to [0,127], TFLite-style fixed-point requantization with
ReLU folded into the clamp, int32 logits + argmax on layer 2 (no requant).
Inference batches 4 images through the 4 array columns (B rows = one
pixel across 4 images) for full utilization. Weights/test vectors are
generated offline by `scripts/train_mlp.py` into `sw/npu_mlp/weights.h`
(the script reads the four MNIST idx `.gz` files from `sw/npu_mlp/data/`,
NOT checked in — fetch them once from
`https://storage.googleapis.com/cvdf-datasets/mnist/` or
`https://ossci-datasets.s3.amazonaws.com/mnist/`);
the on-core test (`sw/npu_mlp/mlp.c`) runs the same batch through the
soft int8 path and the NPU path, requires bit-exact logit agreement plus
agreement with the offline integer reference, and prints both cycle
counts (rdcycle) — that ratio is the reported speedup.

## Measured end-to-end result

Measured D025 runs (32 images, 32/32 classifications correct, NPU logits
bit-exact with the software path) measure:

| Core | Software cycles | NPU cycles | Cycle speedup |
|---|---:|---:|---:|
| 5-stage in-order | 96,367,418 | 1,120,610 | **85.99×** |
| 2-wide OoO | 58,535,712 | 627,343 | **93.30×** |

The displayed ratios match the on-core program's fixed-point x100 output
(truncated to two decimal places).

The offline integer network scores **97.13%** over the full 10,000-image MNIST
test set. The speedups above are cycle-accurate simulation measurements from
the cores' `cycle` CSRs, not physical-board latency measurements. Reproduce
them with `make npu-mlp` and `make npu-mlp-ooo` (or the `scripts\make.cmd`
wrapper in PowerShell).

## Verification

1. **Unit TB** (`tb/verilator/npu_tb.cpp`, `make npu-tb`): drives the raw
   MMIO port of `npu_top` against a C++ golden tile model — thousands of
   random tiles, CLR/GO|CLR/accumulation chains of random length,
   register readback, ID/STATUS semantics.
2. **Lockstep**: all NPU C tests run with the ISS mirror on by default on
   BOTH cores; any RTL/model divergence aborts at the exact instruction.
3. **Directed C tests** in the regression: `sw/ctests/npu_basic.c`
   (register semantics, signed edge cases, accumulate/clear behavior),
   `sw/ctests/npu_matmul.c` (random tiled GEMMs vs software reference).
4. **NPU/MMIO constrained-random** (`make regress-rand-npu`): 25 seeds
   inject staged A/B traffic, back-to-back GO, immediate-producer address
   and store-data dependencies while busy, ordered readbacks, and unmapped
   reads. Measured 2026-07-14: 282 adversarial bursts / 564 GO commands per
   core, both cores 25/25 lockstep-clean. This is the permanent B010/B011 gate.
5. **Assertions** (Verilator-only, `ifdef` guarded): MMIO write while
   busy is fatal on both cores; an IO load completing with an SQ forward
   hit is fatal in the OoO core.
6. Existing suites (`make verify` / `verify-ooo`) must stay green — the
   interlocks only add replay/stall conditions that are quiescent for
   non-IO code.

## FPGA status

The array maps to 16 embedded 9×9 multipliers and is integrated with both
cores. An OoO configuration containing the NPU, M9K-resident program memory,
PLL, and timing constraints has run on the DE10-Lite at 16.67 MHz and booted
standalone from internal flash; that hardware proof used the LED walker, not
NPU inference. The current D029 MNIST top on local branch
`codex/load-wb-bypass-cut` (not merged or pushed)—including M9K-initialized
weights—fits at **34,945 / 49,760 LEs (70%)**, uses **15,140 registers,
632,444 memory bits, and 16 embedded 9×9 multiplier elements**, and reaches
**31.29 MHz** slow-85C Fmax. An actual PLL-/2 build closes at **25 MHz** with
**+8.045 ns** slow-85C setup slack; hold, recovery, and removal are also
positive, and all paths are constrained. The new top-20 family is
ROB-head-to-IQ operand readiness, not the deleted memory/load-WB bypass.

D029 removed that bypass only after an edge-by-edge dependency proof and added
a permanent source-use oracle that reconstructs the old mux priority on every
valid EX uop. Full unit/system/benchmark gates pass with zero lockstep
divergence, and line coverage is **99.3% (1596/1607)** across 61 programs per
core. Freshness-clean PLL-/2 D029 MNIST `.sof` and `.pof` images were assembled
from MIF stamp `mlp`, but remain unflashed. The only hardware-confirmed OoO
image remains the earlier 16.67 MHz LED walker/CFM build; the first physical
MNIST inference is still pending. The **85.99× / 93.30×** speedup table above
retains its D025 provenance because the full MLP benchmark was not rerun for
D026–D029.
