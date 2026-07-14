# Career packet — RISC-V out-of-order SoC with an int8 NPU

This file contains copy-ready language for a résumé, LinkedIn, recruiter
conversations, and technical interviews. Every number below is tied to a
measured result in this repository. The final section defines the claim
boundaries that keep the story accurate.

## Pitches

### One line

I built a measured RV32I + Zicsr FPGA SoC—five-stage and two-wide
out-of-order cores plus a 4×4 int8 NPU—achieving 20.91% higher
CoreMark/MHz, a 93.30× simulated-cycle NPU speedup, and 99.3% RTL line
coverage with retirement lockstep verification.

### 30 seconds

I started with a five-stage RISC-V core and developed it into a two-wide
out-of-order CPU with register renaming, a ROB, an issue queue, speculative
loads, recovery, branch prediction, and store-set memory-dependence
prediction. On the same CoreMark image, it improved IPC from 0.849 to 1.026
and CoreMark/MHz by 20.91%. I also integrated a 4×4 int8 systolic NPU. The
project is verified against an independent instruction-set model, reaches
99.3% RTL line coverage, and has booted standalone on a DE10-Lite FPGA.

### 90 seconds

I wanted to build more than a CPU that could run a few directed tests, so I
treated the project as a measured architecture and verification program. I
first established a five-stage RV32I + Zicsr baseline that runs compiled C
and reportable CoreMark. I then built a two-wide out-of-order core with a
64-register physical namespace, 32-entry reorder buffer, 16-entry issue
queue, load and store queues, speculative-load recovery, gshare/BTB/RAS
prediction, and a store-set memory-dependence predictor.

The comparison uses the same 720-iteration CoreMark image: the in-order core
measures 1.176568 CoreMark/MHz at 0.849 IPC, while the current out-of-order
core measures 1.422552 CoreMark/MHz at 1.026 IPC—a 20.91% improvement per
MHz. I also integrated a memory-mapped 4×4 int8 systolic NPU. On the
out-of-order core it reduces the quantized MNIST workload from 58.5 million
software cycles to 627 thousand NPU cycles, a 93.30× cycle speedup.

The part I am proudest of is the evidence. An independent ISA model compares
every retired instruction, register write, and store. Both cores pass 40/40
rv32ui tests plus directed, constrained-random, memory-ordering, and
randomized-reset suites. Combined RTL line coverage is 99.3%, and 15 real
RTL/SoC bugs have written root-cause reports, with key failures preserved as
permanent regressions. The
in-order core has run at 50 MHz on the DE10-Lite; an OoO revision has run at
16.67 MHz and boots standalone from internal flash. The latest complete top
fits at 70% utilization and closes timing at 25 MHz, with physical testing of
that new image still pending.

## Résumé project entry

**Two-Wide Out-of-Order RISC-V SoC + int8 NPU**

*Verilog, RISC-V assembly/C, C++, Verilator, Intel Quartus, DE10-Lite/MAX 10*

- Designed a bare-metal RV32I + Zicsr SoC spanning a five-stage in-order
  baseline and a two-wide OoO core with register renaming, a 32-entry ROB,
  16-entry IQ, speculative load/store queues, recovery, and store-set
  prediction.
- Improved exact-image CoreMark from **1.176568 to 1.422552 CoreMark/MHz
  (+20.91%)** and IPC from **0.849 to 1.026**, using CRC-validated runs and
  hardware retirement counters.
- Integrated a **4×4 int8 systolic NPU** that achieved **85.99× in-order and
  93.30× OoO cycle speedup** over software; matched software logits bit for
  bit on **32/32 on-core images**, with **97.13%** offline integer MNIST
  accuracy over the full 10,000-image test set.
- Built retirement lockstep co-simulation and reproducible verification:
  **40/40 rv32ui**, directed and constrained-random suites, randomized
  reset/X-state testing, and **99.3% RTL line coverage (1596/1607)** across
  61 programs per core; documented **15 RTL/SoC bugs** and turned key
  failures into permanent regressions.
- Closed the current OoO + NPU FPGA top at **34,945/49,760 LEs (70%)** and
  **31.29 MHz Fmax**; generated a 25 MHz image with **+8.045 ns** slow-corner
  setup slack, after physically demonstrating 50 MHz in-order and 16.67 MHz
  OoO configurations with standalone internal-flash boot.

## LinkedIn material

### About snippet

I am an Electrical Engineering student at the Technion focused on computer
architecture, RTL design, FPGA implementation, and hardware verification. My
main project is a RISC-V SoC that I developed from a five-stage in-order core
into a two-wide out-of-order CPU with speculative memory execution and a
4×4 int8 neural-network accelerator.

I like engineering that can be measured and defended. The project includes
exact-image CoreMark comparisons, retirement lockstep against an independent
ISA model, constrained-random and randomized-reset testing, 99.3% RTL line
coverage, Quartus timing closure, and physical DE10-Lite bring-up with
standalone flash boot. I am especially interested in junior RTL, FPGA,
verification, and computer-architecture roles where careful debugging and
evidence matter as much as the initial design.

### Launch post

I started this project with a basic five-stage RISC-V pipeline. The most
useful decision I made was to stop treating “it runs” as the finish line.

The result is now a measured FPGA SoC with two CPU implementations and a
neural-network accelerator:

- RV32I + Zicsr five-stage in-order baseline
- two-wide out-of-order core with register renaming, ROB/IQ, speculative
  loads, recovery, branch prediction, and store-set prediction
- memory-mapped 4×4 int8 systolic NPU
- independent retirement lockstep, constrained-random tests, randomized
  reset testing, and reproducible benchmark gates

On the exact same reportable CoreMark image, the OoO core moves from 0.849 to
1.026 IPC and improves CoreMark/MHz by **20.91%**. The NPU accelerates the
quantized MNIST workload by **93.30× in simulated CPU cycles** on the OoO
core, while matching the software path bit for bit on 32/32 exported images.
The offline integer model reaches **97.13% accuracy** on the full MNIST test
set.

Verification became as important as the architecture: both cores pass 40/40
rv32ui tests, the complete suite covers 61 programs per core, and merged RTL
line coverage is **99.3% (1596/1607)**. I also documented 15 real RTL/SoC
bugs with their symptoms, root causes, and fixes, and preserved key failures
as permanent regression tests.

The hardware story includes some honest setbacks. The first OoO board port
gained IPC but lost badly in clock speed, which forced me to optimize the
issue logic and memory structures using routed timing data rather than RTL
intuition. The in-order core has run at 50 MHz on a DE10-Lite, and an OoO
revision has run at 16.67 MHz and boots standalone from internal flash. The
latest full OoO + NPU image fits at 70% utilization and closes timing at
25 MHz; that new image is built but has not yet been tested on the board.

Repository, measurements, decision log, and reproduction commands:
https://github.com/hannaashkar/rv32i_cpu

#RISCV #FPGA #ComputerArchitecture #RTLDesign #HardwareVerification

## Interview story bank

Use these as story structures, not scripts to memorize. Lead with the
engineering question, explain the tradeoff, give the measured result, and be
ready to draw the relevant pipeline or timing path.

### 1. Architecture: moving from in-order to out-of-order execution

**Good prompt:** “Tell me about the most complex system you designed.”

**Situation.** The existing five-stage core was useful as a functional
baseline, but it exposed limited instruction-level parallelism and did not
demonstrate modern speculative execution.

**Decision and action.** I kept the ISA and software image fixed, then built a
two-wide R10K-style organization: physical register renaming, a 32-entry ROB,
a 16-entry unified issue queue, and 8-entry load and store queues. I added
checkpointed branch recovery and speculative-load recovery. Rather than
always blocking loads behind unknown stores, I used store sets to predict
which store a load should wait for. I built each structure behind directed
and random tests so failures remained local.

**Result.** On the exact same CoreMark image, IPC increased from 0.849 to
1.026 and CoreMark/MHz increased by 20.91%, with zero retirement divergence
from the reference model.

**What to discuss next.** Explain why a ROB is needed for precise in-order
retirement, how the RAT differs from committed architectural state, how a
load-order violation is detected, and why store sets sit between conservative
ordering and uncontrolled speculation.

### 2. Verification: finding bugs that normal programs miss

**Good prompt:** “How did you know the CPU was correct?”

**Situation.** Passing assembly tests was not enough for a speculative OoO
core because wrong-path and stale-state errors can disappear before a final
program signature is checked.

**Decision and action.** I built an independent C++ model of the implemented
ISA behavior and compared the RTL at retirement: PC, register writeback, and
stores. I combined that with structure-level golden models, 40 rv32ui tests,
directed cases, constrained-random instruction streams, forced load-order
violations, adversarial NPU/MMIO ordering, and randomized reset/X-state
runs. I kept every real failure in a bug log and added a permanent regression
or assertion.

**Concrete example.** A load-violation recovery reused a branch-flush age
calculation. A six-bit relative age could never satisfy the intended “greater
than 63” condition, so the issue queue cleared zero entries and stale uops
could reissue after registers were reallocated. Lockstep isolated the first
bad retirement; the fix added an explicit full-IQ flush for that recovery
path.

**Result.** The current tree is clean across 61 programs per core, 40/40
rv32ui, random and reset suites, with 99.3% RTL line coverage and 15
documented RTL/SoC bugs.

**What to discuss next.** Be explicit that this is dynamic lockstep and
simulation coverage, not formal proof. Explain what is compared, when it is
compared, and what classes of bugs could still escape.

### 3. Performance: learning that IPC is not wall-clock speed

**Good prompt:** “Describe a time measurement changed your design.”

**Situation.** The first OoO implementation improved CoreMark IPC, but its
FPGA Fmax was only 8.42 MHz because a serial issue-queue selection and wakeup
path was roughly 118 ns. It was therefore slower in real time than the 50 MHz
in-order core despite retiring more instructions per cycle.

**Decision and action.** I used Quartus path reports to optimize the measured
critical path. I replaced the serial oldest-ready scan with a balanced
lower-index-preserving tree, retained the former logic as a simulation oracle,
and required cycle-identical lockstep results. Later changes moved expensive
tables into M9K memories and removed a load-writeback bypass only after an
edge-by-edge dependency proof plus a permanent source-use oracle.

**Result.** The first selection rewrite improved characterized Fmax 2.33×
without changing IPC. The current complete top reaches 31.29 MHz routed Fmax
and closes an actual 25 MHz build with +8.045 ns slow-corner setup slack,
while preserving the 1.026 IPC CoreMark result exactly.

**Lesson.** CPU performance on an FPGA is IPC × frequency. Architecture,
logic depth, memory mapping, routing congestion, and clock constraints must
be measured together.

### 4. Failure and recovery: making the MNIST image fit and route

**Good prompt:** “Tell me about a design that failed and what you did next.”

**Situation.** The first full board image with the MNIST program and weights
used 96% of the FPGA logic and failed routing, even though individual RTL
tests and synthesis checks passed.

**Decision and action.** I treated placement and routing as first-class
evidence. Quartus per-entity reports showed that the physical register file
and predictor storage—not the NPU arithmetic—were major logic consumers. I
reworked large asynchronous tables into synchronous M9K-backed structures,
retimed their consumers, and used lockstep and cycle-count gates to prevent
an area fix from silently changing CPU behavior. I also added fit and timing
checks to the normal release process instead of relying on synthesis alone.

**Result.** The current full top fits at 34,945 of 49,760 LEs, or 70%, with
the NPU and initialized MNIST memories present. It reaches 31.29 MHz routed
Fmax and produces timing-clean 25 MHz programming files.

**Lesson.** “Synthesizes” does not mean “fits,” and “fits” does not mean
“meets timing.” On an FPGA, memory architecture and routability are part of
the microarchitecture.

## Technical skills and evidence map

| Skill | Evidence in this project | Measured proof |
|---|---|---|
| CPU microarchitecture | Five-stage pipeline; two-wide rename/dispatch/retire; PRF, RAT, ROB, IQ, SQ/LQ, recovery | Same-image IPC 0.849 → 1.026; CoreMark/MHz +20.91% |
| Memory dependence and speculation | Store-to-load forwarding, violation CAM, replay/recovery, store-set prediction | Directed and random violation stress with retirement lockstep |
| RTL and FPGA implementation | Verilog RTL, M9K-backed memories, PLL/SDC, MMIO, Quartus fit/STA | 70% full-top LE use; 31.29 MHz Fmax; 25 MHz timing closure at +8.045 ns |
| Hardware bring-up | DE10-Lite JTAG, MIF initialization, internal configuration flash | 50 MHz in-order and 16.67 MHz OoO hardware demonstrations; standalone boot |
| Verification engineering | Verilator C++ harness, independent ISA model, structure golden models, assertions, seeded random tests | 40/40 rv32ui; 99.3% line coverage; 61 programs/core; 15 documented bugs |
| Performance analysis | Hardware cycle/instret counters, exact-image A/B methodology, CoreMark CRC checks, routed critical-path analysis | 1.176568 → 1.422552 CoreMark/MHz; cycle-exact timing optimizations |
| ML acceleration | 4×4 output-stationary int8 systolic array, tiled GEMM, quantized MLP, hardware device ordering | 85.99×/93.30× simulated-cycle speedup; 32/32 bit-exact on-core images |
| Embedded software and tooling | Bare-metal startup/runtime, linker scripts, C/assembly tests, CoreMark port, reproducible build scripts, CI | CI-green production RTL baseline `3c3171f`; complete benchmark and verification commands checked in |
| Engineering communication | Architecture decision records, bug reports, benchmark methodology, reproducible handoff docs | 15 root-caused bugs plus explicit evidence and limitation ledgers |

## Claim boundaries

These distinctions make the project stronger, not weaker. Use the precise
claim in the middle column and avoid the broader claim on the right.

| Topic | Accurate claim | Do not claim |
|---|---|---|
| ISA and software | Bare-metal RV32I integer behavior plus Zicsr, compiled C, and CoreMark | Linux-capable, privileged RISC-V, or full platform compliance |
| ISA testing | Passed 40/40 vendored `riscv-tests` rv32ui integer tests | Passed the full RISC-V architectural certification suite |
| Verification | Retirement lockstep co-simulation, assertions, directed/random/reset testing, and 99.3% RTL line coverage | Formal verification, exhaustive proof, or 99.3% functional coverage |
| CoreMark | Cycle-accurate, CRC-validated, same-image result of 1.176568 vs 1.422552 CoreMark/MHz | Physical-board CoreMark throughput unless it is separately run and measured there |
| NPU speedup | 85.99×/93.30× reduction in simulated CPU cycles versus RV32I software without the M extension | Measured FPGA wall-clock speedup, GPU-class performance, or a comparison against an optimized SIMD CPU |
| MNIST accuracy | Offline integer model reached 97.13% on all 10,000 test images | Ran all 10,000 images through RTL or on the FPGA |
| On-core NPU check | NPU and software logits were bit-exact on 32/32 exported images | The 32-image check is the source of the 97.13% figure |
| Physical FPGA proof | In-order core ran at 50 MHz; an earlier OoO revision ran at 16.67 MHz and booted standalone from internal flash | The current 25 MHz OoO + MNIST image has run physically |
| Current 25 MHz image | Quartus fit, STA, and assembly passed; 31.29 MHz routed Fmax and +8.045 ns setup slack at 25 MHz; programming files exist | Hardware-confirmed 25 MHz operation before the image is flashed and exercised |
| Project maturity | Reproducible, CI-green educational/research FPGA project with industry-style verification practices | Production silicon, tapeout, commercial qualification, or an industry-certified core |

### Why it does not run Linux today

The CPU is intentionally a bare-metal RV32I + Zicsr design. It does not
implement the privileged architecture, traps/interrupts, an MMU, virtual
memory, atomics, or an external DRAM platform. Those are required for a
credible Linux claim. Adding only an `ecall` instruction or printing a boot
banner would not change that.

### Short answers for skeptical follow-ups

**“Why is the NPU speedup so large?”**

The CPU implements RV32I without the M extension, so software multiplication
uses helper routines. The NPU performs 16 int8 MACs spatially and keeps int32
partial sums in the array. The reported ratio is still a fair same-workload,
same-core cycle comparison, but it is not a comparison against a CPU with a
hardware multiplier or SIMD unit.

**“Does 99.3% coverage prove correctness?”**

No. It is line coverage, used alongside retirement lockstep, directed tests,
third-party rv32ui tests, constrained random generation, randomized reset
state, assertions, and unit-level golden models. The remaining lines are
published rather than hidden through exclusions.

**“Is the 25 MHz result running on the board?”**

Not yet. The exact current image has passed fit, timing analysis, and
bitstream assembly. Physical evidence currently covers the 50 MHz in-order
configuration and an earlier 16.67 MHz OoO configuration with standalone
flash boot.

**“What does ‘CI-green main’ mean here?”**

It means the repository's automated checks pass at commit `3c3171f`. It does
not mean the design is a commercially deployed product.
