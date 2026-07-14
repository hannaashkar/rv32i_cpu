# Baseline: 5-stage in-order core (v1.0-inorder-baseline)

Measured 2026-07-03. This is the **"before" column** for every future
microarchitecture change — the 2-wide OoO core, BRAM memories, predictor
upgrades — all get compared against these numbers, reproduced with the
same commands.

## Headline numbers

| Metric | Value |
|---|---|
| CoreMark 1.0 (at 50 MHz) | **58.83 iterations/sec** |
| **CoreMark/MHz** | **1.177** |
| Cycles per CoreMark iteration | 849,948 |
| **IPC** (whole run, HW counters) | **0.849** (CPI 1.178) |
| Validation | `Correct operation validated` — seedcrc 0xe9f5, crclist 0xe714, crcmatrix 0x1fd7, crcstate 0x8e3a (official 2K performance-run values) |
| Run length | 600 iterations = 509,968,993 ticks = 10.199 s at 50 MHz (satisfies CoreMark's ≥10 s reporting rule) |
| Whole-run totals | 510,056,361 cycles, 432,888,826 instructions retired |
| Benchmark binary | 32,968 B text, 56 B data, 2,100 B bss (`-O2 -march=rv32i_zicsr`) |

Official report line:

```
CoreMark 1.0 : 58.827106 / GCC15.2.0 -O2 -march=rv32i_zicsr / STATIC
```

## How it was measured

- Timing source is the core's own **cycle CSR**; instruction counts come
  from **instret**, which counts a 1-bit valid flag at WB (decision D012)
  — pipeline bubbles and mispredict flushes are excluded by construction,
  so IPC is exact, not sampled. The Verilator harness prints the same
  counters at exit (`[sim] perf:` line); software and testbench can never
  disagree.
- The run is **cycle-accurate RTL simulation** (Verilator). Wall-clock
  time is irrelevant; "seconds" means cycles ÷ 50 MHz, the DE10-Lite
  clock the design targets. CoreMark's 10-second rule is satisfied in
  simulated time (600 iterations).
- Whole-run IPC includes crt0 and the report printing, but CoreMark's
  timed section is 509.97 M of the 510.06 M total cycles (99.98%), so the
  distinction is noise.

## Reproduce

```
make coremark              # 600 iterations, ~510M cycles (minutes)
make coremark-quick        # quick CRC-only correctness check (~8.5M cycles)
make regress               # 9 directed suites, all green at baseline
```

Current-tree control (2026-07-14): the exact 720-iteration image used for the
D027 OoO comparison reproduced **58.828385 iterations/s = 1.176568
CoreMark/MHz**, IPC 0.849, with `Correct operation validated` and 519,453,759
instructions checked in lockstep. The baseline has not drifted.

Environment: commit tagged `v1.0-inorder-baseline`; Verilator 5.048;
xPack riscv-none-elf-gcc 15.2.0 (`-O2 -march=rv32i_zicsr -mabi=ilp32`);
CoreMark upstream vendored in `sw/coremark/` (Apache-2.0), port layer in
`sw/coremark/rv32/`.

## What the number means

For orientation: PicoRV32 (non-pipelined, size-optimized) documents
~0.52 CoreMark/MHz; classic single-issue 5-stage in-order RISC-V cores
typically land between 1 and 2. **1.177 CoreMark/MHz / IPC 0.849 is
exactly where a healthy 5-stage with branch prediction and single-cycle
memories should sit** — the remaining 0.178 CPI is the sum of:

- 2-cycle mispredict/redirect penalties (64-entry 2-bit BHT + tagged
  BTB + no RAS; CoreMark is branchy — list traversal and state machine),
- 1-cycle load-use stalls (no WB→MEM store bypass, D011; frequent
  pointer chasing in the list benchmark),
- spurious hazard stalls from immediate bits decoded as register fields
  (BUGLOG watch list — a known small leak, fix is rs1/rs2-valid flags).

A per-cause stall counter breakdown (easy csr_file extension) is the
natural next measurement step when OoO work starts, to know exactly
where the 0.178 CPI goes.

## Caveats to carry into the comparison

- **Memories are combinational** (D010): imem and dmem answer in the
  same cycle, i.e. zero wait states — flattering relative to the planned
  synchronous BRAM rework (B006), which will add fetch/load latency.
  When B006 lands, re-run this measurement and record both numbers.
- The 50 MHz figure is the target clock, not a measured Fmax; timing
  closure work (B005 ripple clock, PLL + SDC) is deliberately
  post-baseline.
- rv32i soft multiply/divide (`__mulsi3`/`__divsi3` from libgcc) is part
  of the measured profile — the M extension would change both IPC and
  CoreMark/MHz substantially. That's a fair fight: the OoO core will run
  the identical binary.
