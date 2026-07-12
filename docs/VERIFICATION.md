# Verification strategy

The verification stack has five independent stimulus layers, all of them
checked by the same **golden-model lockstep co-simulation** — so every
test contributes checking at every retired instruction, not just at its
final CHECK.

## Lockstep co-simulation (the backbone)

`tb/verilator/iss.h` is an independent ~300-line RV32I+Zicsr instruction
-set simulator. On every retired instruction (`validW`), the harness
steps the ISS and compares:

- the retired **PC**,
- the **register writeback** (rd and value) when one occurs,
- every **store** in program order (address, size, full rs2 word — this
  is what catches forwarding bugs like B007/B008 at the exact
  instruction).

First divergence aborts with a diff dump (exit code 3). Lockstep is ON
by default for every `+imem` run; `+nolockstep` disables it.

Free-running counters (cycle/instret) are microarchitectural, so the RTL
value is injected into the model at those CSR reads — the standard
co-sim compromise. Everything else, including the SoC's documented
quirks (memory aliasing, word-only MMIO loads, misaligned lane math), is
modeled exactly; a quirk is architecture once documented.

## Stimulus layers

| Layer | Command | What it adds |
|---|---|---|
| Directed suites (`sw/tests/*.S`, `sw/ctests/*.c`) | `make regress` | Targeted corner cases: hazards found as real bugs (B004/B007/B008 regressions), BTB-stale returns, sub-word lanes, CSR semantics, exact instret deltas, the C runtime |
| Official ISA tests (riscv-tests rv32ui, vendored) | `make regress-isa` | 40/40 third-party acceptance tests — the industry's definition of "implements RV32I" |
| Constrained-random (`scripts/gen_random_test.py`) | `make regress-rand` | 25 seeds × 3000 instructions of weighted-random mix incl. misaligned accesses and dense hazards; forward-only control flow guarantees termination; reproducible by seed |
| LQ-violation stress (`--vio` mode, OoO only) | `make regress-rand-vio` | Same 25 seeds but with a late-store/early-load-to-same-address pattern injected so the D020 speculative-load violation CAM + poison + flush-at-head recovery actually fires (1185 real violations across the seeds; the plain seeds essentially never violate). Guards B013. |
| Benchmark | `make coremark` | 433M-instruction real-workload run, CRC-validated AND lockstep-checked |

`make verify` = regress + regress-isa + regress-rand. `make verify-ooo` adds
`regress-rand-vio` (the LQ recovery path). All green is the merge gate for
`main`.

## Coverage (measured 2026-07-11)

`make coverage` builds line-coverage-instrumented models of BOTH cores,
runs the directed + C + ISA suites on each (59 programs per core),
merges the per-test data, and prints the combined figure. Current:

- **RTL line coverage: 99.0% (1338/1351 lines)**, both cores combined.
- Merged lcov data lands in `build/cov/coverage.info` for annotation.
- The uncovered tail is dominated by decode paths no test executes yet
  (FENCE / ECALL / EBREAK / reserved opcodes) — a known gap on the
  audit list, closed by adding them to the random mix once decided.

## Divergence diagnostics

On any lockstep mismatch the harness prints, besides the mismatching
instruction: the last 64 retired instructions (cycle, pc, writeback,
store), a full ISS architectural register dump, and a pointer to
`+trace_at=<cycle>` — which opens the FST only at the given cycle, so a
divergence 90M instructions into CoreMark gets a usable waveform window
on the second run. `+force_diverge=<n>` is a permanent TB self-test that
fires the whole path on demand (verified on both cores).

## Exclusions (documented, not hidden)

- **fence_i**: the imem is Harvard with no store path — self-modifying
  code is architecturally impossible on this SoC.
- **ma_data**: misaligned accesses don't trap (no traps yet); the lane
  behavior is documented in dmem.v and modeled identically in the ISS.

## Bug log

Every real bug found is recorded in [BUGLOG.md](BUGLOG.md) with symptom,
root cause, how it was caught, and the fix (B001–B008 so far; two of
them — B007, B008 — were found by this infrastructure).
