// ============================================================================
// mlp.c — quantized MNIST MLP (784→32→10) on rv32i_cpu, soft vs NPU
// (docs/NPU.md, decisions D014/D015)
//
// Runs MLP_NTEST images in batches of 4 (one batch = the 4 columns of the
// systolic array) through TWO implementations of the same integer pipeline:
//   soft — plain C int8 matmuls (each MAC is a __mulsi3 libcall: rv32i has
//          no hardware multiply — this is the honest CPU baseline)
//   npu  — 4x4x4 tiles on the systolic array (A = weight rows as packed
//          words, B = activations interleaved [k][image])
// PASS requires: (1) soft and NPU logits bit-exact for every batch,
// (2) predictions match the offline numpy integer reference
// (test_expected), (3) image-0 logits match test_logits0 exactly.
// Cycle counts for both paths print to the sim console; their ratio is
// the reported speedup. Exit protocol: return 0 -> PASS.
//
// Build/run: make npu-mlp (in-order) / make npu-mlp-ooo (OoO core).
// ============================================================================
#include "../common/rv32.h"
#include "../common/npu.h"
#include "weights.h"

// word-aliasing view of int8 arrays (rows are 4-byte aligned; stride 784
// and 32 are both multiples of 4, so every 4-byte group is one LW)
typedef uint32_t __attribute__((may_alias)) u32a;

// ---------------------------------------------------------------------------
// tiny console (harness snoops stores to MMIO_SIM_CONSOLE; no-op on HW)
// ---------------------------------------------------------------------------
static void putc_(char c) { MMIO_SIM_CONSOLE = (uint32_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void put_u32(uint32_t v) {
    char b[10]; int n = 0;
    do { b[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) putc_(b[--n]);
}

// ---------------------------------------------------------------------------
// shared requantization (bit-exact contract with train_mlp.py / weights.h):
// h = clamp((acc * M1 + (1 << (N1-1))) >> N1, 0, 127), computed in int64
// ---------------------------------------------------------------------------
static int8_t requant(int32_t acc) {
    int64_t t = ((int64_t)acc * (int64_t)M1 + (1LL << (N1 - 1))) >> N1;
    if (t < 0)   t = 0;                    // ReLU
    if (t > 127) t = 127;                  // int8 saturation
    return (int8_t)t;
}

// batch buffers: activations interleaved [k][image] so one word = one
// B-register row (B[k][j] = value k for image j)
static int8_t  xt[MLP_IN][4]  __attribute__((aligned(4)));
static int8_t  h_s[MLP_H][4]  __attribute__((aligned(4)));   // soft hidden
static int8_t  h_n[MLP_H][4]  __attribute__((aligned(4)));   // npu hidden
static int32_t lg_s[MLP_OUT_PAD][4];                         // soft logits
static int32_t lg_n[MLP_OUT_PAD][4];                         // npu logits

// ---------------------------------------------------------------------------
// soft path: plain int8 GEMM + requant (every product a __mulsi3 call)
// ---------------------------------------------------------------------------
static void soft_batch(void) {
    for (int i = 0; i < MLP_H; i++) {
        int32_t acc[4] = { b1[i], b1[i], b1[i], b1[i] };
        for (int k = 0; k < MLP_IN; k++) {
            int32_t w = w1[i][k];
            acc[0] += w * xt[k][0];
            acc[1] += w * xt[k][1];
            acc[2] += w * xt[k][2];
            acc[3] += w * xt[k][3];
        }
        for (int img = 0; img < 4; img++) h_s[i][img] = requant(acc[img]);
    }
    for (int j = 0; j < MLP_OUT_PAD; j++) {
        int32_t acc[4] = { b2[j], b2[j], b2[j], b2[j] };
        for (int i = 0; i < MLP_H; i++) {
            int32_t w = w2[j][i];
            acc[0] += w * h_s[i][0];
            acc[1] += w * h_s[i][1];
            acc[2] += w * h_s[i][2];
            acc[3] += w * h_s[i][3];
        }
        for (int img = 0; img < 4; img++) lg_s[j][img] = acc[img];
    }
}

// ---------------------------------------------------------------------------
// NPU path: same math as 4x4x4 tiles. A rows = 4 consecutive weight rows
// (packed words), B rows = interleaved activations. Row/K dims are exact
// multiples of 4 (784, 32; W2 padded to 12 rows), so no edge cases.
// ---------------------------------------------------------------------------
static void npu_gemm_layer(const int8_t *w, const int *bias,
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
        for (int i = 0; i < 4; i++)
            for (int img = 0; img < 4; img++) {
                int32_t acc = NPU_C(i * 4 + img) + bias[rt + i];
                if (out_h)  out_h[rt + i][img]  = requant(acc);
                else        out_lg[rt + i][img] = acc;
            }
    }
}

static void npu_batch(void) {
    npu_gemm_layer(&w1[0][0], b1, xt,  h_n, 0,    MLP_H,       MLP_IN);
    npu_gemm_layer(&w2[0][0], b2, h_n, 0,   lg_n, MLP_OUT_PAD, MLP_H);
}

static int argmax10(const int32_t lg[][4], int img) {
    int best = 0;
    for (int j = 1; j < MLP_OUT; j++)
        if (lg[j][img] > lg[best][img]) best = j;
    return best;
}

int main(void) {
    if (NPU_ID != NPU_ID_VALUE) return 2;

    uint32_t soft_cycles = 0, npu_cycles = 0;
    int correct = 0;

    for (int base = 0; base < MLP_NTEST; base += 4) {
        // interleave the batch: xt[k][img] = pixel k of image base+img
        for (int img = 0; img < 4; img++)
            for (int k = 0; k < MLP_IN; k++)
                xt[k][img] = test_images[base + img][k];

        uint32_t t0 = rdcycle();
        soft_batch();
        uint32_t t1 = rdcycle();
        npu_batch();
        uint32_t t2 = rdcycle();
        soft_cycles += t1 - t0;
        npu_cycles  += t2 - t1;

        // (1) both paths bit-exact, incl. the zero padding rows
        for (int j = 0; j < MLP_OUT_PAD; j++)
            for (int img = 0; img < 4; img++)
                if (lg_s[j][img] != lg_n[j][img]) return 3;

        // (3) image 0: logits match the offline integer reference exactly
        if (base == 0)
            for (int j = 0; j < MLP_OUT; j++)
                if (lg_n[j][0] != test_logits0[j]) return 4;

        // (2) predictions match the offline reference; count accuracy
        for (int img = 0; img < 4; img++) {
            int pred = argmax10(lg_n, img);
            if (pred != (int)test_expected[base + img]) return 5;
            if (pred == (int)test_labels[base + img]) correct++;
        }
    }

    puts_("[mlp] images: ");            put_u32(MLP_NTEST);
    puts_("  correct: ");               put_u32((uint32_t)correct);
    puts_("\n[mlp] soft: ");            put_u32(soft_cycles);
    puts_(" cycles\n[mlp] npu:  ");     put_u32(npu_cycles);
    puts_(" cycles\n[mlp] speedup: ");
    { // fixed-point x100 ratio
        uint32_t r = (uint32_t)(((uint64_t)soft_cycles * 100u) / npu_cycles);
        put_u32(r / 100u); putc_('.');
        putc_((char)('0' + (r / 10u) % 10u));
        putc_((char)('0' + r % 10u));
    }
    puts_("x\n");

    return 0;
}
