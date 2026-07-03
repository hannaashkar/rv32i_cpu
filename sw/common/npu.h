// ============================================================================
// npu.h — driver for the 4x4 int8 output-stationary systolic NPU
// (rtl/npu/, docs/NPU.md, decision D014)
//
// One GO streams one 4x4x4 tile: C[i][j] += sum_k A[i][k]*B[k][j].
// Accumulators persist across GOs (K tiling); CLR zeroes them; GO|CLR on
// the first k-tile. Word access ONLY (volatile uint32_t / int32_t) — the
// hardware interlocks handle ALL ordering, software never polls STATUS.
// ============================================================================
#ifndef NPU_H
#define NPU_H

#include <stdint.h>

#define NPU_ID_VALUE 0x4E505501u

#define NPU_ID     (*(volatile uint32_t *)0x50000000u)
#define NPU_STATUS (*(volatile uint32_t *)0x50000004u)  // b0 busy, b1 done
#define NPU_CTRL   (*(volatile uint32_t *)0x50000008u)
#define NPU_A(i)   (*(volatile uint32_t *)(0x50000010u + ((uint32_t)(i) << 2)))
#define NPU_B(k)   (*(volatile uint32_t *)(0x50000020u + ((uint32_t)(k) << 2)))
#define NPU_C(n)   (*(volatile int32_t  *)(0x50000040u + ((uint32_t)(n) << 2)))

#define NPU_GO  1u
#define NPU_CLR 2u

// pack 4 int8 (byte 0 = lowest lane) into one register word
static inline uint32_t npu_pack(const int8_t *p) {
    return (uint32_t)(uint8_t)p[0]
         | ((uint32_t)(uint8_t)p[1] << 8)
         | ((uint32_t)(uint8_t)p[2] << 16)
         | ((uint32_t)(uint8_t)p[3] << 24);
}

// one k-tile from row-major operands: A rows at a + i*lda (4 int8 each),
// B rows at b + k*ldb. ctrl = NPU_GO|NPU_CLR on the first tile of an
// output tile, NPU_GO on the rest.
static inline void npu_tile(const int8_t *a, int lda,
                            const int8_t *b, int ldb, uint32_t ctrl) {
    NPU_A(0) = npu_pack(a);
    NPU_A(1) = npu_pack(a + lda);
    NPU_A(2) = npu_pack(a + 2 * lda);
    NPU_A(3) = npu_pack(a + 3 * lda);
    NPU_B(0) = npu_pack(b);
    NPU_B(1) = npu_pack(b + ldb);
    NPU_B(2) = npu_pack(b + 2 * ldb);
    NPU_B(3) = npu_pack(b + 3 * ldb);
    NPU_CTRL = ctrl;
}

// read the 16 accumulators (row-major) into c[16]
static inline void npu_read_c(int32_t *c) {
    for (int n = 0; n < 16; n++) c[n] = NPU_C(n);
}

#endif // NPU_H
