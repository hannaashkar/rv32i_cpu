// ============================================================================
// hello.c — first compiled-C program on the core; doubles as the C-runtime
// acceptance test. Exercises everything crt0/link.ld must get right:
//   .rodata (const table + string), .data (initialized global), small-data
//   via gp, .bss (zeroing), the stack (real recursion), libgcc (rv32i has
//   no M extension, so * and / become __mulsi3/__divsi3 calls), libmin
//   (memcpy/strcmp/strlen), and the D012 counters.
// Returns 0 on success -> crt0 reports PASS; fail codes are never 1.
// ============================================================================
#include "../common/rv32.h"

const int  table[5]   = {7, 11, 13, 17, 19};   // .rodata
const char greeting[] = "hello, rv32i";        // .rodata
int        scale      = 100;                   // initialized data (dmem image)
unsigned   bss_probe[32];                      // .bss — must arrive zeroed

static int fib(int n) {                        // stack: real call frames
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

int main(void) {
    // .bss zeroed by crt0
    for (int i = 0; i < 32; i++)
        if (bss_probe[i] != 0) return 2;

    // .rodata arrived in the dmem image
    int sum = 0;
    for (int i = 0; i < 5; i++) sum += table[i];
    if (sum != 67) return 3;

    // .data read-modify-write + libgcc soft multiply/divide
    scale = (scale * sum) / 25;                // __mulsi3, __divsi3
    if (scale != 268) return 4;

    // stack discipline across real calls
    if (fib(10) != 55) return 5;

    // libmin against .rodata
    char buf[16];
    memcpy(buf, greeting, sizeof(greeting));
    if (strcmp(buf, "hello, rv32i") != 0) return 6;
    if (strlen(buf) != 12) return 7;

    // counters live and monotonic from C
    uint32_t c0 = rdcycle();
    uint32_t i0 = rdinstret();
    for (volatile int i = 0; i < 10; i++) ;
    if (rdcycle() <= c0)   return 8;
    if (rdinstret() <= i0) return 9;

    return 0;                                  // PASS
}
