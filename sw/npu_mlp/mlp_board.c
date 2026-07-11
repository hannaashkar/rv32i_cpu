// ============================================================================
// mlp_board.c — standalone MNIST demo for the DE10-Lite (D023)
//
// The board-facing sibling of mlp.c: same quantized 784→32→10 network, same
// weights.h, NPU path only. Two phases:
//
//   1) SELF-TEST (also the sim regression): classify test images 0..7 and
//      compare against the offline numpy integer reference
//      (test_expected). Result -> MMIO_SIM_EXIT: the Verilator harness
//      exits here (PASS/fail), the FPGA ignores that store and continues.
//
//   2) INTERACTIVE LOOP (board only — sim never reaches it): forever,
//      read SW[2:0] to select one of the 8 baked-in images, classify it
//      on the NPU, and show on the 7-segment displays:
//          HEX5 = selected image number      (flip switches to change)
//          HEX2 = true label                 (what a human says it is)
//          HEX0 = the network's prediction   (what the CPU+NPU say)
//      LEDR[sel] marks the selected image; LEDR9 lights on a correct
//      prediction. HEX2==HEX0 on all 8 images at 97%-accuracy weights.
//
// One image per classify: the systolic array batches 4 columns, so the
// selected image rides column 0 and columns 1-3 are zero (their results
// are simply ignored — reads are side-effect-free, D014).
//
// Build: make mlp-board   Sim check: make npu-mlp-board[-ooo]
// Fits the board memories by construction: linked with link_board.ld
// (8 KB imem / 64 KB dmem) so overflow is a LINK error, not a mystery.
// ============================================================================
#include "../common/rv32.h"
#include "../common/npu.h"
#include "weights.h"

#define NDEMO 8                       // SW[2:0] selects among these images

typedef uint32_t __attribute__((may_alias)) u32a;

// requantization — bit-exact contract with train_mlp.py (see mlp.c)
static int8_t requant(int32_t acc) {
    int64_t t = ((int64_t)acc * (int64_t)M1 + (1LL << (N1 - 1))) >> N1;
    if (t < 0)   t = 0;
    if (t > 127) t = 127;
    return (int8_t)t;
}

// single-image buffers, image in column 0, columns 1-3 zero
static int8_t  xt[MLP_IN][4] __attribute__((aligned(4)));
static int8_t  hid[MLP_H][4] __attribute__((aligned(4)));
static int32_t logits[MLP_OUT_PAD][4];

// NPU tiled GEMM — same loop as mlp.c's npu_gemm_layer (see there for the
// A/B packing derivation)
static void npu_layer(const int8_t *w, const int *bias,
                      const int8_t act[][4], int8_t out_h[][4],
                      int32_t out_lg[][4], int rows, int cols) {
    for (int rt = 0; rt < rows; rt += 4) {
        const u32a *a0 = (const u32a *)(w + (rt + 0) * cols);
        const u32a *a1 = (const u32a *)(w + (rt + 1) * cols);
        const u32a *a2 = (const u32a *)(w + (rt + 2) * cols);
        const u32a *a3 = (const u32a *)(w + (rt + 3) * cols);
        const int ktiles = cols >> 2;
        for (int kt = 0; kt < ktiles; kt++) {
            const u32a *bx = (const u32a *)&act[kt * 4][0];
            NPU_A(0) = a0[kt];
            NPU_A(1) = a1[kt];
            NPU_A(2) = a2[kt];
            NPU_A(3) = a3[kt];
            NPU_B(0) = bx[0];
            NPU_B(1) = bx[1];
            NPU_B(2) = bx[2];
            NPU_B(3) = bx[3];
            NPU_CTRL = (kt == 0) ? (NPU_GO | NPU_CLR) : NPU_GO;
        }
        for (int i = 0; i < 4; i++) {
            int32_t acc = NPU_C(i * 4) + bias[rt + i];   // column 0 only
            if (out_h)  out_h[rt + i][0]  = requant(acc);
            else        out_lg[rt + i][0] = acc;
        }
    }
}

// classify test image n on the NPU; returns the predicted digit 0-9
static int classify(int n) {
    for (int k = 0; k < MLP_IN; k++) {
        xt[k][0] = test_images[n][k];
        xt[k][1] = 0; xt[k][2] = 0; xt[k][3] = 0;
    }
    for (int i = 0; i < MLP_H; i++) {
        hid[i][1] = 0; hid[i][2] = 0; hid[i][3] = 0;
    }
    npu_layer(&w1[0][0], b1, xt,  hid, 0,      MLP_H,       MLP_IN);
    npu_layer(&w2[0][0], b2, hid, 0,   logits, MLP_OUT_PAD, MLP_H);
    int best = 0;
    for (int j = 1; j < MLP_OUT; j++)
        if (logits[j][0] > logits[best][0]) best = j;
    return best;
}

int main(void) {
    if (NPU_ID != NPU_ID_VALUE) { MMIO_SIM_EXIT = 2; for (;;) ; }

    // ---- phase 1: self-test (the sim regression ends at the store) ----
    uint32_t fails = 0;
    for (int n = 0; n < NDEMO; n++) {
        MMIO_LEDS = 1u << n;                      // progress bar on the board
        if (classify(n) != (int)test_expected[n]) fails++;
    }
    MMIO_SIM_EXIT = fails ? 3 : 1;                // sim: exit; board: no-op

    // ---- phase 2: interactive demo loop (board only) ----
    uint32_t shown = 0xFFFFFFFFu;                 // force first draw
    for (;;) {
        uint32_t sel = MMIO_SWITCHES & (NDEMO - 1);
        if (sel == shown) continue;               // redraw only on change
        shown = sel;

        int pred  = classify((int)sel);
        int label = (int)test_labels[sel];

        // HEX3..HEX0: [ blank | true label | blank | prediction ]
        MMIO_HEXLO = ((uint32_t)HEX_BLANK        << 24)
                   | ((uint32_t)hex_font[label]  << 16)
                   | ((uint32_t)HEX_BLANK        << 8)
                   |  (uint32_t)hex_font[pred];
        // HEX5,HEX4: [ image number | blank ]
        MMIO_HEXHI = ((uint32_t)hex_font[sel] << 8) | (uint32_t)HEX_BLANK;

        MMIO_LEDS = (1u << sel) | (pred == label ? (1u << 9) : 0u);
    }
}
