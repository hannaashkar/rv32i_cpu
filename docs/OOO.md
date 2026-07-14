# ooo_cpu — 2-wide out-of-order core specification

> **Superseded in part (2026-07-11).** This file is the D013 contract and
> is current for rename/ROB/IQ/SQ/branch handling — but the **memory
> model below predates D020/D021**: loads are no longer always
> conservative. The shipping default is speculative loads with an 8-entry
> load queue + violation CAM (`ooo_lq.v`, D020) gated by a store-set
> memory-dependence predictor (`ooo_stset.v`, D021, `LOAD_POLICY=2`);
> conservative mode survives as `LOAD_POLICY=0`. For the current memory
> ordering rules read **docs/STORESET.md** and the D020/D021 entries in
> **docs/DECISIONS.md**. Statements below about "no LQ" are the
> historical D013 simplification, kept for the record.

> **Current implementation note (D027).** The eight-entry SQ still obeys the
> D013 architectural contract, but its youngest-older forwarding/replay query
> is now a cycle-exact fixed 8→4→2→1 reduction tree with the original serial
> scan retained as a live Verilator oracle. The independent lifecycle model,
> invariants, exact selection rules, and routed timing result are documented in
> **[SQ_TIMING.md](SQ_TIMING.md)**. This is an implementation optimization—no
> SQ state, load latency, ordering rule, or IPC changed.

> **Current implementation note (D028).** Port 1 no longer waits for an
> oldest-ALU pick, a one-hot clear, and a second complete pick. One balanced
> sorted-pair tree returns the oldest two candidates together, with the old
> topology retained as Verilator oracle INV-I1. The public grants remain
> combinational, `hello.c` remains 2013 cycles / 1882 instret, and no issue or
> dependency latency changed. The independent 300,553-cycle IQ model and
> routed evidence are in **[IQ_TIMING.md](IQ_TIMING.md)**. The full both-core
> verification gate and fresh 99.2% line coverage are green. Reportable
> CoreMark is cycle-exact to D027 at 1.422552 CoreMark/MHz and IPC 1.026, with
> official CRCs and zero divergence. D028 is fully signed off but remains
> local—not merged or pushed. Freshness-clean MNIST `.sof`/`.pof` images are
> assembled at PLL /3 but unflashed, so D028 is not hardware-confirmed.

## Measured result (2026-07-03, same binary as the baseline)

| Metric | in-order (v1.0 tag) | **ooo_cpu** | delta |
|---|---|---|---|
| CoreMark/MHz | 1.177 | **1.397** | **+18.8%** |
| Cycles / CoreMark iteration | 849,948 | **715,615** | 1.188× faster |
| IPC (whole run, HW counters) | 0.849 | **1.008** | +18.7% |
| Verification | lockstep-clean | **519,454,226 instructions, zero divergence** | same suites |

Official report line (720 iterations = 10.3 simulated seconds — the OoO
core needed MORE iterations than the baseline's 600 to satisfy the
10-second rule, which is its own kind of result):

```
CoreMark 1.0 : 69.869960 / GCC15.2.0 -O2 -march=rv32i_zicsr / STATIC
Correct operation validated.
```

Same flags, same libgcc soft-mul/div profile, same memories. Known IPC
headroom deliberately left for later measured stages: speculative loads +
LQ (the conservative-load policy costs list-benchmark IPC), a wider
in-flight branch budget, and the B006 memory rework. Reproduce:
`make verify-ooo && make coremark-ooo CM_ITER=720`.


Decision D013 (see DECISIONS.md for the options considered). This file is
the binding contract between the OoO modules — read it before touching
any of them. The in-order core (`cpu_pipeline`) remains in the tree
untouched as the measured baseline; `ooo_cpu` is a drop-in replacement
top with the identical external interface (clk, reset, leds, switches).

## Parameters

| Structure | Size | Notes |
|---|---|---|
| Physical registers | 64 × 32b | merged PRF (R10K style); p0 ≡ 0, never allocated |
| RAT | 32 × 6b | speculative map; x0 → p0 always |
| Free list | ring of 32 tags | initially p32..p63 |
| ROB | 32 entries | 2-wide alloc/retire; stores result value (lockstep/debug) |
| Issue queue | 16 entries | unified, age = ROB tag order, select ≤3/cycle (1/port); balanced oldest and top-two tournaments (D019/D028) |
| Store queue | 8 entries | alloc at rename, fill at EX, commit at retire |
| Checkpoints | 8 | per control-flow op (branch/JALR): RAT+flhead+sqtail+GHR+RAS-TOS |
| gshare | 1024 × 2b PHT, 10b GHR | speculative GHR update at fetch, repair on restore |
| BTB | 64 entries, tagged | trained at resolve (and decode for JAL) |
| RAS | 8 deep | maintained at decode; TOS checkpointed, content not |

## Pipeline

```
F  (fetch 2: pc, pc+4; gshare/BTB predict; unaligned pairs OK)
D  (2 × decode; JAL + RAS-ret decode-redirect — fixes BTB misses before
    any OoO state is touched)
R  (rename 2: RAT read/write incl. intra-pair dep; freelist alloc;
    ROB alloc; IQ dispatch; SQ alloc for stores; checkpoint alloc for
    branches/JALR; CSR ops serialize: stall until ROB empty)
IS (select ≤3: port0 ALU+branch/JALR, port1 ALU+CSR, port2 AGU/mem;
    ALU/branch ops broadcast dest tag AT SELECT — dependents can go
    back-to-back; loads broadcast at WRITEBACK instead, because a load
    can replay)
RF (PRF read, 6R; write-first internal bypass)
EX (ALUs, branch resolve vs prediction, AGU + SQ forward-check + dmem
    read; WB-stage result bus bypasses into EX operands)
WB (PRF write 3W; ROB done + result value; load tag broadcast)
RT (retire ≤2 in order from ROB head; ≤1 store/cycle -> SQ commit to
    dmem/mmio; free old ptag; free checkpoint; instret += count)
```

## Contracts that must not be broken

- **Age comparison**: every in-flight uop carries a 6-bit ROB tag
  (5 index + 1 wrap phase). "A older than B" = (tagA - head) < (tagB -
  head) in 6-bit unsigned arithmetic... implemented as
  `(tagA - head_tag) < (tagB - head_tag)` where head_tag includes phase.
- **Squash**: on mispredict (resolved on port0 only — at most one per
  cycle), kill F/D/R, kill IQ entries younger than the branch, kill
  younger uops in RF/EX/WB pipeline regs, ROB tail <- branch+1, restore
  RAT/freelist-head/SQ-tail/GHR/RAS-TOS from the branch's checkpoint.
  Older in-flight uops continue unharmed. The mispredicting branch
  itself still retires normally.
- **Checkpoints** are allocated at rename for every conditional branch
  and JALR (ring, 8 deep — rename stalls if full), freed at that
  branch's retire; a squash rewinds the allocation pointer to
  mispredicting-branch+1. Out-of-order resolution is safe because every
  in-flight branch keeps its own checkpoint until retire (nested
  restores land on still-live older checkpoints).
- **Loads are conservative**: a load issues only when all older SQ
  entries have known addresses. Same-word full-word store -> forward;
  same-word partial store -> replay the load (stays in IQ) until that
  store commits; no overlap -> read dmem. No speculation = no
  memory-ordering violations = no LQ needed (documented simplification;
  an LQ arrives with speculative disambiguation later).
- **Stores** execute (addr+data capture) out of order into the SQ but
  commit to memory strictly at retire, ≤1/cycle. All memory-mapped
  side effects (LEDs, sim-exit, sim-console) are therefore
  non-speculative. MMIO **loads** may execute speculatively — this
  SoC's MMIO reads (LEDs readback, switches, all NPU registers) are
  side-effect-free.
- **IO loads are strongly ordered** (added with the NPU, D014 — also
  fixed latent B010): a load to region 0x4/0x5 replays until every
  older store has left the SQ (new `q_older` query output), and NPU
  loads additionally until the array is idle. The SQ drain gained
  backpressure (`mw_ready`): a committed store bound for a busy NPU
  waits at the head instead of corrupting a running pass. Details and
  the no-deadlock/no-livelock arguments live in docs/NPU.md.
- **CSR ops serialize**: rename holds a CSR op until the ROB is empty,
  so it cannot be on a wrong path and csr_file's execute-in-EX write
  stays safe. It then flows as a normal port1 op.
- **JAL never enters the OoO window as a branch**: its target is known
  at decode; a BTB miss is fixed by a decode-redirect (flush F/D only).
  Its rd link value is computed as an ALU pass-through of pc+4. JALR
  resolves on port0 like a branch. RAS `ret` prediction also corrects
  at decode.
- **Lockstep interface** (harness contract): 2 retire slots
  {valid, pc, wr, rd, value} where value comes from the ROB, plus the
  committed-store stream {valid, addr, data, funct3} at the SQ commit
  port. cycle/instret CSR reads inject the RTL value into the ISS,
  same as the in-order core.

## Shared modules

alu.v, alu_control.v (via uop fields), branch_unit.v, alu_ops.vh,
csr_file.v (retire strobe widened to a 2-bit count), imem/dmem/mmio
(read/write address ports split so fetch/load/commit can use them
concurrently; the in-order top ties both to the same signal).
