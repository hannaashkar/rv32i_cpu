# On-board demos — DE10-Lite quick guide

How to flash and drive the two board demos. The flashing procedure and the
LED walker are hardware-proven (2026-07-11); the MNIST demo is
lockstep-verified in simulation on both cores — its first board flash is
the acceptance step. **The MNIST bitstream now builds** — D024 first made
the design routable by moving the gshare PHT into M9Ks; D025 then moved the
6R/3W PRF into 18 M9Ks, D026 balanced the LQ violation selector, and D027
balanced the SQ forwarding/replay selector without changing a cycle. The
current top on local branch `codex/sq-forward-tree` (not merged or pushed)
fits at **34,787 / 49,760 LEs (70%)**, reaches **25.47 MHz**
slow-85C Fmax, and closes timing at 16.67 MHz with **+20.745 ns** setup and
**+0.337 ns** hold slack; every timing check is positive and zero paths are
unconstrained. Fresh `.sof` and `.pof` images were assembled from the D027
PLL-/3 fit on 2026-07-14 and are ready to flash, but neither D027 image has
been programmed on the board. (Before D024 it failed to
route at 96% LEs — if you are on an older checkout and hit "Can't route",
that is why.) If anything surprises you, the board state section at the
bottom is the first thing to check.

The board top (`rtl/top/de10_top.v`) is the **2-wide out-of-order core**
with the store-set predictor and the NPU, clocked at **16.67 MHz** (PLL /3
from the 50 MHz oscillator). Which *program* the FPGA runs is decided at
compile time by the MIF images in `synth/`:

| `make` target | Program in the bitstream |
|---|---|
| `make mif` (default) | **MNIST demo** — switch-selected digit recognition |
| `make mif MIF_PROG=demo` | LED walker (the D022 bring-up acceptance test) |

After switching MIFs, recompile in Quartus (Processing → Start Compilation)
and reflash. The `.mif` files are checked in, so a fresh clone builds the
MNIST demo without any software toolchain.

## Flashing (Quartus Programmer GUI)

1. Board on, USB cable in. Open Quartus → **Tools → Programmer**.
2. **Hardware Setup…** → select `USB-Blaster [USB-0]` → Close.
   (Missing? Install the driver from
   `C:\intelfpga_lite\20.1\quartus\drivers\usb-blaster` via Device Manager.)
3. **Auto Detect** → the chain shows one `10M50DA` device.
4. **Change File…** → `synth/output_files/rv32i_cpu.sof` → tick
   **Program/Configure** → **Start**. Seconds later the design is live.
   `.sof` = volatile: lost on power-cycle.
5. To make it permanent: **Change File…** → `rv32i_cpu.pof`, tick
   **Program/Configure** + **Verify**, **Start** (~1 min). The design now
   boots from the MAX 10's internal flash on power-up, no PC needed.

CLI equivalent, from `synth/`:
`quartus_pgm -m jtag -o "p;output_files/rv32i_cpu.sof"` (or `"pv;...pof"`).

## The MNIST demo (D023)

At power-up / reset (KEY0) the program first **self-tests**: it classifies
all 8 built-in images and lights one LED per image as a progress bar. Then
it enters the interactive loop:

- **SW[2:0]** selects one of 8 handwritten-digit images (from the MNIST
  test set, baked into the data memory at synthesis).
- The CPU drives the NPU through the two matrix multiplies of a quantized
  784→32→10 network (~47k cycles ≈ 3 ms at 16.67 MHz — instant) and shows:

```
  HEX5          HEX2      HEX0
  image number  label     prediction
  (switches)    (truth)   (the network's answer)
```

- **LEDR9** lights when prediction == label. **LEDR[7:0]** shows which
  image is selected. With the shipped weights all 8 images classify
  correctly, so HEX2 and HEX0 always match — flip switches and watch the
  answer track the truth.

Once flashed, this will exercise end-to-end on silicon: the banked M9K
instruction ROM, the MIF-initialized 64 KB block-RAM data memory (weights
present at power-up — there is no loader), the OoO core's IO-ordering
interlocks against a busy NPU, the systolic array itself, and the new
7-segment MMIO path. Until that acceptance step, these are simulation +
fit/STA claims, not an on-board inference claim. The same binary's self-test
phase runs in the Verilator regression
(`make npu-mlp-board[-ooo]`), lockstep-compared against the golden model.

## The LED walker (D022 bring-up test)

A single lit LED walks LEDR0→LEDR9 and back, self-paced in software.
Boring on purpose: every instruction fetch crosses the even/odd M9K banks
and the parity crossbar, so a steady walk is the acceptance test for the
banked instruction memory. Use it when bisecting a board problem — if the
walker runs, fetch/PLL/timing are healthy.

## Board state notes

- Displays dark + LEDs dead → press KEY0 (reset). Still dead → reflash.
- The last documented `.pof` programmed and verified in the MAX 10 flash is
  the earlier 16.67 MHz OoO LED walker/CFM image—not D027 and not MNIST
  inference. Check `git log synth/` to correlate any later manually
  programmed bitstream.
- Pin assignments in `synth/rv32i_cpu.qsf` are copied from the proven
  build and are **not to be edited**; the HEX0-5 pins (added 2026-07-11,
  D023) were verified against two independent DE10-Lite references.
