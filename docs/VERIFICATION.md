# Verification strategy

The verification stack combines independent unit tests with eight system-level
verification lanes, all of them
checked by the same **golden-model lockstep co-simulation** — so every
test contributes checking at every retired instruction, not just at its
final CHECK.

## Lockstep co-simulation (the backbone)

`tb/verilator/iss.h` is an independently implemented ~300-line model of the
project's RV32I compute/load-store/control-flow + Zicsr and counter behavior. On
every retired instruction (`validW`), the harness
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
| LQ golden-model unit (OoO only) | `make lq-tb` | Directed lifecycle/age/wrap/pre-edge cases plus 250,000 random cycles against an independent C++ model; includes the B015 one-free-slot allocation reproducer and checks the D026 tree against the original serial selector every cycle |
| Directed suites (`sw/tests/*.S`, `sw/ctests/*.c`) | `make regress` | Targeted corner cases: hazards found as real bugs (B004/B007/B008 regressions), BTB-stale returns, sub-word lanes, CSR semantics, exact instret deltas, the C runtime |
| Third-party integer tests (`riscv-tests` rv32ui, vendored) | `make regress-isa` | 40/40 integer-instruction acceptance tests; this is not a privileged/trap compliance claim |
| Constrained-random (`scripts/gen_random_test.py`) | `make regress-rand` | 25 seeds × 3000 instructions of weighted-random mix incl. misaligned accesses and dense hazards; forward-only control flow guarantees termination; reproducible by seed |
| System/decode-tail random (`--sys`) | `make regress-rand-sys` | 25 seeds × 3000 instructions with low-weight FENCE, ECALL, EBREAK, and reserved-opcode injection; proves the documented no-trap NOP contract at retirement without perturbing the established default seeds |
| NPU/MMIO ordering random (`--npu`) | `make regress-rand-npu` | 25 seeds × 3000 instructions with staged A/B traffic, back-to-back GO, busy-time address/data dependencies, readbacks, and unmapped accesses; targets B010/B011 while the ISS mirrors every NPU access |
| Randomized startup/reset | `make regress-x` | Separate `--x-assign unique --x-initial unique` model; the full directed+C suite is replayed at four explicit `+verilator+rand+reset+2` seeds to expose state that accidentally depends on Verilator's normal zero initialization |
| LQ-violation stress (`--vio` mode, OoO only) | `make regress-rand-vio` | Same 25 seeds but with a late-store/early-load-to-same-address pattern injected so the D020 speculative-load violation CAM + poison + flush-at-head recovery actually fires (1185 real violations across the seeds; the plain seeds essentially never violate). Guards B013. |
| Benchmark | `make coremark` | 433M-instruction real-workload run, CRC-validated AND lockstep-checked |

`make verify` = regress + regress-isa + regress-rand + regress-rand-sys +
regress-rand-npu + regress-x. `make verify-ooo` additionally requires
`lq-tb`, adds `regress-rand-vio` (the LQ recovery path), and runs the OoO
X-state model. All green is the merge gate for `main`.

## Coverage (measured 2026-07-14 on D026)

`make coverage` builds line-coverage-instrumented models of BOTH cores,
runs the directed + C + ISA suites on each (60 programs per core),
merges the per-test data, and prints the combined figure. Current:

- **RTL line coverage: 99.2% (1449/1461 lines)**, both cores combined.
- Merged lcov data lands in `build/cov/coverage.info` for annotation.
- The former decode tail is closed: `sw/tests/sys_nops.S` proves exact
  retirement plus no register/CSR/memory side effects, and the 25-seed
  `--sys` lane injected **1,148** system/reserved words on each core with
  zero lockstep divergence. Neither core's control/decode module has an
  uncovered line now.
- The remaining 12 uncovered lines are defensive/default or configuration
  paths in ALU control, memory initialization, SQ recovery, and MMIO; they
  are not being hidden as "100%" via exclusions.

## Divergence diagnostics

On any lockstep mismatch the harness prints, besides the mismatching
instruction: the last 64 retired instructions (cycle, pc, writeback,
store), a full ISS architectural register dump, and a pointer to
`+trace_at=<cycle>` — which opens the FST only at the given cycle, so a
divergence 90M instructions into CoreMark gets a usable waveform window
on the second run. `+force_diverge=<n>` is a permanent TB self-test that
fires the whole path on demand (verified on both cores).

## Reset/X-state robustness (measured 2026-07-14)

Normal Verilator startup initializes storage to zero, which can hide a missing
reset. `regress-x` uses separate model directories compiled with
`--x-assign unique --x-initial unique`, then runs the complete directed+C
suite at four explicit randomized-reset seeds. The shipping/deterministic
models and benchmark cycle counts are untouched.

- In-order: **80/80** program-seed runs, lockstep-clean.
- OoO: **80/80** program-seed runs, lockstep-clean.
- The lane is now a prerequisite of `make verify` / `make verify-ooo`.

## Exclusions (documented, not hidden)

- **fence_i**: the imem is Harvard with no store path — self-modifying
  code is architecturally impossible on this SoC.
- **ma_data**: misaligned accesses don't trap (no traps yet); the lane
  behavior is documented in dmem.v and modeled identically in the ISS.

## Bug log

Every real RTL/SoC integration bug found is recorded in
[BUGLOG.md](BUGLOG.md) with symptom, root cause, how it was caught, and the
fix (**B001–B015**, 15 unique bugs). Several exist as permanent directed,
random, assertion, or recovery-stress regressions rather than anecdotes.
