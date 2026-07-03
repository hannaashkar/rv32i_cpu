// ============================================================================
// npu_matmul.c — random tiled GEMM on the NPU vs a software int8 reference
// (docs/NPU.md, D014). LCG-generated operands, two shapes:
//   8x8x8   — 2x2 output tiles, K chains of 2
//   4x4x12  — one output tile, K chain of 3
// Every NPU result word is also lockstep-compared against the ISS mirror.
// Returns 0 -> PASS; distinct fail codes otherwise (never 1).
// ============================================================================
#include "../common/rv32.h"
#include "../common/npu.h"

static uint32_t lcg_state = 0x2A5F1CB3u;
static int8_t rnd8(void) {
    lcg_state = lcg_state * 1664525u + 1013904223u;
    return (int8_t)(lcg_state >> 24);
}

// software reference: C[M][N] += A[M][K] * B[K][N], int8 in, int32 out
static void soft_gemm(const int8_t *a, const int8_t *b, int32_t *c,
                      int M, int N, int K) {
    for (int i = 0; i < M; i++)
        for (int j = 0; j < N; j++) {
            int32_t acc = 0;
            for (int k = 0; k < K; k++)
                acc += (int32_t)a[i * K + k] * (int32_t)b[k * N + j];
            c[i * N + j] = acc;
        }
}

// NPU: same GEMM via 4x4x4 tiles (M, N, K multiples of 4)
static void npu_gemm(const int8_t *a, const int8_t *b, int32_t *c,
                     int M, int N, int K) {
    for (int it = 0; it < M; it += 4)
        for (int jt = 0; jt < N; jt += 4) {
            for (int kt = 0; kt < K; kt += 4)
                npu_tile(a + it * K + kt, K,
                         b + kt * N + jt, N,
                         kt == 0 ? (NPU_GO | NPU_CLR) : NPU_GO);
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    c[(it + i) * N + (jt + j)] = NPU_C(i * 4 + j);
        }
}

static int8_t  A[8 * 12];
static int8_t  B[12 * 8];
static int32_t C_soft[8 * 8];
static int32_t C_npu[8 * 8];

static int check(int M, int N, int K, int code) {
    for (int i = 0; i < M * K; i++) A[i] = rnd8();
    for (int i = 0; i < K * N; i++) B[i] = rnd8();
    soft_gemm(A, B, C_soft, M, N, K);
    npu_gemm(A, B, C_npu, M, N, K);
    for (int i = 0; i < M * N; i++)
        if (C_soft[i] != C_npu[i]) return code;
    return 0;
}

int main(void) {
    int r;
    if ((r = check(8, 8, 8, 2)) != 0)  return r;
    if ((r = check(4, 4, 12, 3)) != 0) return r;
    if ((r = check(8, 4, 8, 4)) != 0)  return r;
    return 0;
}
