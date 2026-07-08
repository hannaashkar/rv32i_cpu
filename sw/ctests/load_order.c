// ============================================================================
// load_order.c — store->load ordering stress (LQ increment 0 oracle).
//
// Exercises the exact pattern speculative loads must get right: a load whose
// address matches an OLDER store that may not have executed its address yet,
// interleaved with independent work that (on a speculative core) lets the
// load issue early and then be violated + replayed. On the current
// CONSERVATIVE core it must already pass — this test is the golden oracle
// that must keep passing bit-for-bit once the LQ lands.
//
// Every check is value-based (the loaded value must equal the last store to
// that address in program order), so it is an exact memory-ordering test, not
// a timing test. Returns 0 (PASS) via crt0 if all checks hold; a nonzero
// failure code otherwise.
// ============================================================================
#include "../common/rv32.h"

// volatile array in dmem: forces real loads/stores (no reg promotion), so the
// store->load forwarding / ordering path is actually exercised.
static volatile int buf[16];

// an independent computation to interleave between store and load, giving a
// speculative core room to issue the load before the older store's address is
// known (defeated by the LQ's violation check).
static int busywork(int x) {
    int a = x;
    for (int i = 0; i < 3; i++) a = a * 3 + i;   // soft mul, no memory
    return a;
}

int main(void) {
    int acc = 0;

    // --- Pattern 1: store then load SAME word, with work in between --------
    // The load must observe the store even though independent work sits
    // between them (on a speculative core the load could issue before the
    // store's address resolves -> must be caught & replayed).
    for (int i = 0; i < 16; i++) {
        buf[i] = i * 7 + 1;            // store
        int t = busywork(i);           // independent work (no buf access)
        acc += t & 1;                  // consume t so it isn't optimized away
        if (buf[i] != i * 7 + 1)       // load same word -> must see the store
            return 10 + i;             // FAIL: stale load
    }

    // --- Pattern 2: overwrite + reload, address computed at runtime --------
    // Two stores to the same word then a load; the load must see the SECOND
    // store. A runtime index defeats constant-address analysis.
    int idx = (acc & 7);
    buf[idx] = 0x1111;
    buf[idx] = 0x2222;                 // younger store to same word
    if (buf[idx] != 0x2222) return 30; // must see the newer store

    // --- Pattern 3: store to A, load from B (no conflict) then load A ------
    // The B load has NO older conflicting store -> a speculative core should
    // issue it early and NOT be violated; the A load must still see A's store.
    buf[3] = 0xABCD;
    buf[9] = 0x5678;
    int rb = buf[9];                   // independent (different word) load
    int ra = buf[3];                   // conflicting-with-3 load
    if (rb != 0x5678) return 40;
    if (ra != 0xABCD) return 41;

    // --- Pattern 4: partial-word (byte/half) store then word load ----------
    // A sub-word store to a word then a word load of it: the conservative
    // core replays until commit; the LQ must keep this correct too.
    volatile unsigned char *bp = (volatile unsigned char *)&buf[5];
    buf[5] = 0;
    bp[0] = 0xDE; bp[1] = 0xAD;        // two byte stores
    if ((buf[5] & 0xFFFF) != 0xADDE) return 50;

    // --- Pattern 5: pointer-chase-ish dependent loads ----------------------
    // Fill a small linked layout in buf and walk it: load feeds the next
    // load's address. Stresses load->load dependence + store visibility.
    buf[0] = 2; buf[2] = 4; buf[4] = 6; buf[6] = 0;
    int p = 0, steps = 0, sum = 0;
    for (steps = 0; steps < 8; steps++) {
        sum += p;
        int nxt = buf[p];
        if (nxt == 0) break;
        p = nxt;
    }
    if (sum != (0 + 2 + 4 + 6)) return 60;

    (void)acc;
    return 0;   // PASS
}
