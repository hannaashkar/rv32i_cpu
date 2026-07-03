// ============================================================================
// riscv_test.h — rv32i_cpu target environment for the official riscv-tests
//
// This is the designed porting mechanism of riscv-tests: the test bodies
// (vendored unmodified from riscv-software-src/riscv-tests) include this
// header for everything platform-specific. Here that maps onto the SoC's
// conventions:
//   * _start at pc=0 in .text.init (our link.ld places it first)
//   * PASS/FAIL via the magic MMIO exit store (0x40000008): 1 = PASS,
//     else fail code = TESTNUM (the failing subtest number, always >= 2)
//   * test data lives in .data -> the dmem image at 0x10000000
// No trap setup: the core has no traps yet, and rv32ui-p tests need none
// (fence_i and ma_data are excluded — see docs/VERIFICATION.md).
// Additionally, every retired instruction of every test is checked against
// the golden-model ISS by the lockstep harness.
// ============================================================================
#ifndef _ENV_RV32I_CPU_TEST_H
#define _ENV_RV32I_CPU_TEST_H

#define RVTEST_RV32U
#define RVTEST_RV64U            // rv32ui wrappers redefine this to RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
        .section .text.init; \
        .globl _start;       \
_start:

#define RVTEST_CODE_END

#define RVTEST_PASS   \
        li a0, 0x40000008; \
        li a1, 1;          \
        sw a1, 0(a0);      \
1:      j 1b;

#define RVTEST_FAIL   \
        li a0, 0x40000008;  \
        sw TESTNUM, 0(a0);  \
1:      j 1b;

#define RVTEST_DATA_BEGIN .section .data; .align 4;
#define RVTEST_DATA_END

#endif
