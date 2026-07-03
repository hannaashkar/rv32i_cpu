#!/usr/bin/env python3
"""
train_mlp.py -- offline training + int8 quantization pipeline for the NPU MLP.

Trains a float 784 -> 32 (ReLU) -> 10 MLP on MNIST with plain numpy
(SGD + momentum, softmax cross-entropy), then applies post-training
symmetric per-tensor int8 quantization and exports sw/npu_mlp/weights.h
for the RISC-V + NPU firmware.

Everything is deterministic (seed = 1): same data, same shuffles, same
init => bit-identical weights.h on every run.

Quantization scheme (must match the NPU/firmware exactly):
  input   : x in [0,1], xq = round(x*127)            int8 in [0,127], sx = 1/127
  layer 1 : W1q = round(W1/s1), s1 = max|W1|/127     int8
            b1q = round(b1/(s1*sx))                  int32
            acc1 = W1q @ xq + b1q                    int32 (fits: 784*127*127 ~ 1.26e7)
  requant : h = clamp((acc1*M1 + (1 << (N1-1))) >> N1, 0, 127)
            computed in int64, arithmetic shift; M1/2^N1 ~ (s1*sx)/sh
            (the clamp at 0 IS the ReLU; the clamp at 127 is saturation)
  layer 2 : W2q = round(W2/s2), s2 = max|W2|/127     int8
            b2q = round(b2/(s2*sh))                  int32
            logits_q = W2q @ h + b2q                 int32, prediction = argmax
            (no requant on layer 2)

Hidden scale sh: default sh = 1/127 (h saturates at real value 1.0). If that
saturation costs more than 1% accuracy vs float, we fall back to a calibrated
sh = max_hidden_activation/127 measured on 1000 training samples. Whichever
was used is recorded in weights.h.

Usage:  python scripts/train_mlp.py
Only dependency: numpy (2.x).
"""

import gzip
import time
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------- constants
SEED = 1
IN, H, OUT = 784, 32, 10
OUT_PAD = 12          # w2/b2 padded to 12 rows (NPU tile multiple), pad rows = 0
NTEST_EXPORT = 32     # first 32 official test images exported for the on-FPGA self-test

EPOCHS = 15
BATCH = 64
LR = 0.1              # epochs 0-9
LR_LATE = 0.02        # epochs 10-14 (simple step decay to settle the minimum)
MOMENTUM = 0.9

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "sw" / "npu_mlp" / "data"
HEADER_PATH = ROOT / "sw" / "npu_mlp" / "weights.h"


# ---------------------------------------------------------------- MNIST idx
def load_idx_images(path):
    """Parse an idx3-ubyte .gz file -> float32 array (N, 784) in [0,1]."""
    with gzip.open(path, "rb") as f:
        raw = np.frombuffer(f.read(), dtype=np.uint8)
    # idx3 header: magic(2051), count, rows, cols -- 4 big-endian uint32s
    magic, count, rows, cols = raw[:16].view(">u4")
    assert magic == 2051, f"{path}: bad magic {magic}"
    imgs = raw[16:].reshape(count, rows * cols)
    return imgs.astype(np.float32) / 255.0


def load_idx_labels(path):
    """Parse an idx1-ubyte .gz file -> int64 array (N,)."""
    with gzip.open(path, "rb") as f:
        raw = np.frombuffer(f.read(), dtype=np.uint8)
    magic, count = raw[:8].view(">u4")
    assert magic == 2049, f"{path}: bad magic {magic}"
    return raw[8:8 + count].astype(np.int64)


# ---------------------------------------------------------------- float MLP
def float_forward(X, W1, b1, W2, b2):
    """Full float forward pass. Returns (logits, hidden_after_relu)."""
    h = np.maximum(X @ W1.T + b1, 0.0)
    return h @ W2.T + b2, h


def train(Xtr, ytr, Xte, yte, rng):
    """SGD+momentum training loop. Returns trained (W1, b1, W2, b2)."""
    # He init for the ReLU layer, Xavier-ish for the linear output layer.
    W1 = (rng.standard_normal((H, IN)) * np.sqrt(2.0 / IN)).astype(np.float32)
    b1 = np.zeros(H, dtype=np.float32)
    W2 = (rng.standard_normal((OUT, H)) * np.sqrt(1.0 / H)).astype(np.float32)
    b2 = np.zeros(OUT, dtype=np.float32)
    vW1 = np.zeros_like(W1); vb1 = np.zeros_like(b1)
    vW2 = np.zeros_like(W2); vb2 = np.zeros_like(b2)

    n = len(Xtr)
    for epoch in range(EPOCHS):
        lr = LR if epoch < 10 else LR_LATE
        perm = rng.permutation(n)
        for i in range(0, n, BATCH):
            idx = perm[i:i + BATCH]
            x, y = Xtr[idx], ytr[idx]
            m = len(idx)

            # forward
            a1 = x @ W1.T + b1                     # (m, H) pre-activation
            hid = np.maximum(a1, 0.0)              # ReLU
            logits = hid @ W2.T + b2               # (m, OUT)

            # softmax cross-entropy gradient: dL/dlogits = (p - onehot)/m
            z = logits - logits.max(axis=1, keepdims=True)   # stability
            e = np.exp(z)
            p = e / e.sum(axis=1, keepdims=True)
            g = p
            g[np.arange(m), y] -= 1.0
            g /= m

            # backprop
            gW2 = g.T @ hid
            gb2 = g.sum(axis=0)
            ga1 = (g @ W2) * (a1 > 0.0)            # ReLU mask
            gW1 = ga1.T @ x
            gb1 = ga1.sum(axis=0)

            # SGD + momentum
            vW2 = MOMENTUM * vW2 - lr * gW2; W2 += vW2
            vb2 = MOMENTUM * vb2 - lr * gb2; b2 += vb2
            vW1 = MOMENTUM * vW1 - lr * gW1; W1 += vW1
            vb1 = MOMENTUM * vb1 - lr * gb1; b1 += vb1

        logits, _ = float_forward(Xte, W1, b1, W2, b2)
        acc = float(np.mean(np.argmax(logits, axis=1) == yte))
        print(f"  epoch {epoch + 1:2d}/{EPOCHS}  lr={lr:<5g} test acc = {acc * 100:.2f}%")

    return W1, b1, W2, b2


# ------------------------------------------------------------- quantization
def quantize_multiplier(real_scale):
    """
    TFLite-style normalized fixed-point multiplier: find (M, N) with
    M in [2^30, 2^31) such that M / 2^N ~= real_scale.
    Then  (acc * M + (1 << (N-1))) >> N  ==  round(acc * real_scale).
    """
    assert real_scale > 0.0
    m, e = np.frexp(real_scale)          # real_scale = m * 2^e,  m in [0.5, 1)
    M = int(round(float(m) * (1 << 31)))  # m * 2^31 in [2^30, 2^31]
    if M == (1 << 31):                   # m rounded up to exactly 1.0
        M >>= 1
        e += 1
    N = 31 - int(e)
    assert (1 << 30) <= M < (1 << 31), f"M1 out of range: {M}"
    assert 0 < N < 63, f"N1 out of range: {N}"
    return M, N


def quantize(W1, b1, W2, b2, sh):
    """Symmetric per-tensor int8 quantization of both layers for a given sh."""
    sx = 1.0 / 127.0

    s1 = float(np.max(np.abs(W1))) / 127.0
    W1q = np.round(W1 / s1).astype(np.int8)          # in [-127, 127]
    b1q = np.round(b1 / (s1 * sx)).astype(np.int32)

    M1, N1 = quantize_multiplier((s1 * sx) / sh)

    s2 = float(np.max(np.abs(W2))) / 127.0
    W2q = np.round(W2 / s2).astype(np.int8)
    b2q = np.round(b2 / (s2 * sh)).astype(np.int32)

    return dict(sx=sx, s1=s1, s2=s2, sh=sh,
                W1q=W1q, b1q=b1q, M1=M1, N1=N1, W2q=W2q, b2q=b2q)


def int_forward(Xq, q):
    """
    Bit-exact integer pipeline (what the NPU computes). Xq: (n, 784) in [0,127].
    Returns (logits int32 (n,10), hidden codes (n,32) in [0,127]).
    """
    Xq = Xq.astype(np.int64)
    # layer 1 accumulate -- values fit int32, computed in int64 for the requant
    acc1 = Xq @ q["W1q"].T.astype(np.int64) + q["b1q"].astype(np.int64)
    # requant: rounding right-shift in int64 (numpy >> on signed = arithmetic
    # shift); clamp low = ReLU, clamp high = int8 saturation
    h = (acc1 * q["M1"] + (np.int64(1) << (q["N1"] - 1))) >> np.int64(q["N1"])
    h = np.clip(h, 0, 127)
    # layer 2: plain int32 accumulate, no requant -- argmax only needs order
    logits = h @ q["W2q"].T.astype(np.int64) + q["b2q"].astype(np.int64)
    return logits.astype(np.int32), h.astype(np.int32)


# ------------------------------------------------------------ header export
def fmt_1d(vals, per_line=16, indent="    "):
    """Format a 1-D int sequence as C initializer lines."""
    out = []
    for i in range(0, len(vals), per_line):
        out.append(indent + ", ".join(str(int(v)) for v in vals[i:i + per_line]) + ",")
    return "\n".join(out)


def fmt_2d(mat, per_line=16):
    """Format a 2-D int array as nested C initializer rows."""
    rows = []
    for r in mat:
        rows.append("  {\n" + fmt_1d(r, per_line) + "\n  },")
    return "\n".join(rows)


def write_header(path, q, stats, imgs32, labels32, expected32, logits0):
    sx, s1, s2, sh = q["sx"], q["s1"], q["s2"], q["sh"]
    txt = f"""/*
 * weights.h -- int8 MLP (784 -> 32 ReLU -> 10) for the rv32i_cpu NPU stage.
 * AUTO-GENERATED by scripts/train_mlp.py (seed = {SEED}) -- DO NOT EDIT.
 *
 * Float test accuracy   : {stats['float_acc'] * 100:.2f}%  (10000 MNIST test images)
 * Integer test accuracy : {stats['int_acc'] * 100:.2f}%  (same 10000 images, full int pipeline)
 * Accuracy on the {NTEST_EXPORT} exported images: {stats['acc32_hits']}/{NTEST_EXPORT}
 *
 * Scales (symmetric per-tensor):
 *   sx = 1/127 = {sx:.9g}   (input:  xq = round(x*127), x in [0,1])
 *   s1 = {s1:.9g}   (W1: s1 = max|W1|/127)
 *   s2 = {s2:.9g}   (W2: s2 = max|W2|/127)
 *   sh = {sh:.9g}   ({stats['sh_mode']})
 *
 * Integer pipeline (bit-exact contract with scripts/train_mlp.py):
 *   acc1[i]   = sum_k w1[i][k]*xq[k] + b1[i]                       (int32)
 *   h[i]      = clamp((acc1[i]*(int64)M1 + (1LL << (N1-1))) >> N1, 0, 127)
 *               -- int64 multiply, arithmetic shift; M1/2^N1 ~= (s1*sx)/sh
 *               -- clamp low = ReLU, clamp high = int8 saturation
 *   logits[j] = sum_i w2[j][i]*h[i] + b2[j]                        (int32)
 *   class     = argmax_j logits[j]   (rows 10..11 of w2/b2 are zero padding)
 */
#ifndef NPU_MLP_WEIGHTS_H
#define NPU_MLP_WEIGHTS_H

#define MLP_IN      784
#define MLP_H       32
#define MLP_OUT     10
#define MLP_OUT_PAD 12
#define MLP_NTEST   32

/* Layer 1 weights, w1[i][k] = row i of W1q (hidden neuron i). */
static const signed char w1[MLP_H][MLP_IN] __attribute__((aligned(4))) = {{
{fmt_2d(q['W1q'])}
}};

/* Layer 1 bias, b1q = round(b1/(s1*sx)). */
static const int b1[MLP_H] __attribute__((aligned(4))) = {{
{fmt_1d(q['b1q'], per_line=8)}
}};

/* Requant constants: h = clamp((acc1*M1 + (1 << (N1-1))) >> N1, 0, 127). */
static const int M1 = {q['M1']};
static const int N1 = {q['N1']};

/* Layer 2 weights: 10 real rows + 2 all-zero padding rows. */
static const signed char w2[MLP_OUT_PAD][MLP_H] __attribute__((aligned(4))) = {{
{fmt_2d(pad_rows(q['W2q'], OUT_PAD))}
}};

/* Layer 2 bias: 10 real + 2 zero padding entries. */
static const int b2[MLP_OUT_PAD] __attribute__((aligned(4))) = {{
{fmt_1d(np.concatenate([q['b2q'], np.zeros(OUT_PAD - OUT, dtype=np.int32)]), per_line=6)}
}};

/* First {NTEST_EXPORT} official MNIST test images, quantized: round(pixel/255*127), 0..127. */
static const signed char test_images[MLP_NTEST][MLP_IN] __attribute__((aligned(4))) = {{
{fmt_2d(imgs32)}
}};

/* True labels of the {NTEST_EXPORT} images. */
static const unsigned char test_labels[MLP_NTEST] __attribute__((aligned(4))) = {{
{fmt_1d(labels32)}
}};

/* Integer-pipeline predictions for the {NTEST_EXPORT} images (self-test golden output). */
static const unsigned char test_expected[MLP_NTEST] __attribute__((aligned(4))) = {{
{fmt_1d(expected32)}
}};

/* Integer logits of test image 0 (debug aid: compare against NPU output). */
static const int test_logits0[10] __attribute__((aligned(4))) = {{
{fmt_1d(logits0, per_line=10)}
}};

#endif /* NPU_MLP_WEIGHTS_H */
"""
    with open(path, "w", newline="\n") as f:
        f.write(txt)


def pad_rows(mat, total_rows):
    """Pad a 2-D int array with all-zero rows up to total_rows."""
    if len(mat) == total_rows:
        return mat
    pad = np.zeros((total_rows - len(mat), mat.shape[1]), dtype=mat.dtype)
    return np.vstack([mat, pad])


# --------------------------------------------------------------------- main
def main():
    t0 = time.time()
    rng = np.random.default_rng(SEED)

    print("Loading MNIST ...")
    Xtr = load_idx_images(DATA_DIR / "train-images-idx3-ubyte.gz")
    ytr = load_idx_labels(DATA_DIR / "train-labels-idx1-ubyte.gz")
    Xte = load_idx_images(DATA_DIR / "t10k-images-idx3-ubyte.gz")
    yte = load_idx_labels(DATA_DIR / "t10k-labels-idx1-ubyte.gz")
    print(f"  train {Xtr.shape}, test {Xte.shape}")

    print(f"Training float MLP {IN}-{H}-{OUT} "
          f"(SGD+momentum, batch={BATCH}, {EPOCHS} epochs, seed={SEED}) ...")
    W1, b1, W2, b2 = train(Xtr, ytr, Xte, yte, rng)

    logits_f, _ = float_forward(Xte, W1, b1, W2, b2)
    float_acc = float(np.mean(np.argmax(logits_f, axis=1) == yte))
    print(f"Float test accuracy: {float_acc * 100:.2f}%")

    # -------- quantize; input codes for the whole test set
    Xq_test = np.round(Xte * 127.0).astype(np.int8)   # [0,127]

    # Option A: fixed sh = 1/127 (h == int8 code of ReLU clipped at 1.0)
    q_fix = quantize(W1, b1, W2, b2, sh=1.0 / 127.0)
    logits_fix, _ = int_forward(Xq_test, q_fix)
    acc_fix = float(np.mean(np.argmax(logits_fix, axis=1) == yte))
    print(f"Int accuracy, sh = 1/127 (saturating at 1.0): {acc_fix * 100:.2f}%")

    # Option B: sh calibrated so 127 = max hidden activation on 1000 train samples
    _, hid_cal = float_forward(Xtr[:1000], W1, b1, W2, b2)
    max_act = float(hid_cal.max())
    q_cal = quantize(W1, b1, W2, b2, sh=max_act / 127.0)
    logits_cal, _ = int_forward(Xq_test, q_cal)
    acc_cal = float(np.mean(np.argmax(logits_cal, axis=1) == yte))
    print(f"Int accuracy, sh = max_act/127 (max_act = {max_act:.4f} "
          f"on 1000 train samples): {acc_cal * 100:.2f}%")

    # Keep sh = 1/127 unless its saturation costs more than 1% vs float.
    if float_acc - acc_fix <= 0.01:
        q, int_acc = q_fix, acc_fix
        sh_mode = "fixed sh = 1/127; saturation at 1.0 verified harmless"
    else:
        q, int_acc = q_cal, acc_cal
        sh_mode = f"calibrated sh = max_hidden_activation/127, max = {max_act:.6g} over 1000 train samples"
    print(f"Chosen: {sh_mode}")
    print(f"Integer test accuracy (10000 images): {int_acc * 100:.2f}% "
          f"(float - int = {(float_acc - int_acc) * 100:.2f} pts)")

    # -------- export set: first 32 official test images
    imgs32 = Xq_test[:NTEST_EXPORT]
    labels32 = yte[:NTEST_EXPORT]
    logits32, _ = int_forward(imgs32, q)
    expected32 = np.argmax(logits32, axis=1)
    acc32_hits = int(np.sum(expected32 == labels32))
    print(f"Integer accuracy on the {NTEST_EXPORT} exported images: "
          f"{acc32_hits}/{NTEST_EXPORT}")
    assert acc32_hits >= 29, "export set accuracy below 29/32 -- retune training"

    stats = dict(float_acc=float_acc, int_acc=int_acc,
                 acc32_hits=acc32_hits, sh_mode=sh_mode)
    write_header(HEADER_PATH, q, stats, imgs32, labels32, expected32,
                 logits32[0])
    print(f"Wrote {HEADER_PATH}")

    print("\n==== summary ====")
    print(f"float test acc : {float_acc * 100:.2f}%")
    print(f"int   test acc : {int_acc * 100:.2f}%")
    print(f"32-img self-test: {acc32_hits}/{NTEST_EXPORT}")
    print(f"M1 = {q['M1']}, N1 = {q['N1']}  (s1={q['s1']:.6g}, s2={q['s2']:.6g}, sh={q['sh']:.6g})")
    print(f"runtime: {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()
