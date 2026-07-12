/* =============================================================================
   link_board.ld — board-sized variant of link.ld (D023)

   Identical layout to link.ld (read that file's header for the full
   derivation — Harvard split, .dmem_origin sentinel, gp anchoring); the
   ONLY difference is the MEMORY sizes, which here match the synthesized
   FPGA memories instead of the 256 KB SIM_BIG_MEM simulation memories:

       IMEM  8 KB  (rtl/mem/imem_banked.v DEPTH_WORDS = 2048)
       DMEM 64 KB  (rtl/mem/dmem.v        DEPTH_WORDS = 16384)

   Linking a board program against THIS script makes "doesn't fit the
   board" a link-time error instead of silent on-chip address aliasing.
   Keep the sizes in lockstep with the RTL parameters above.

   (_stack_top = end of DMEM = 0x10010000. Its dmem index bits are all
   zero — same benign wrap as link.ld's 256 KB top: the first push
   decrements first, landing on the last real dmem word.)
============================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 8K
    DMEM (rw) : ORIGIN = 0x10000000, LENGTH = 64K
}

_stack_top = ORIGIN(DMEM) + LENGTH(DMEM);   /* grows down from dmem's end */

SECTIONS
{
    .text : {
        *(.text.init)          /* crt0 first: _start must sit at pc = 0 */
        *(.text*)
    } > IMEM

    .dmem_origin : { KEEP(*(.dmem_origin)) } > DMEM

    /* .srodata lives with .rodata here (NOT in .sdata as in link.ld):
       it is constant data, and the guard below must only see truly
       WRITABLE initialized sections. Cost: small const objects lose gp
       relaxation on this board script — correctness is unaffected. */
    .rodata : { *(.rodata*) *(.srodata*) } > DMEM

    .data : { *(.data*) } > DMEM

    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.sdata*)
    } > DMEM

    /* KEY0 warm-reset guard (audit 2026-07-11): the dmem MIF is loaded
       only at device CONFIGURATION. KEY0 restarts _start without
       reloading it; crt0 re-zeroes .bss but nothing can restore .data —
       so a board program with initialized writable data would silently
       run its second pass on corrupted globals. Make that a link error
       instead: board programs must keep writable globals zero-initialized
       (.bss/.sbss) or const (.rodata). */
    ASSERT(SIZEOF(.data) == 0 && SIZEOF(.sdata) == 0,
        "link_board.ld: initialized writable data (.data/.sdata) is forbidden in board programs - KEY0 warm reset does not reload the dmem MIF; use zero-initialized or const data")

    . = ALIGN(4);
    __bss_start = .;
    .sbss : { *(.sbss*) *(.scommon) } > DMEM
    .bss  : { *(.bss*)  *(COMMON)   } > DMEM
    . = ALIGN(4);
    __bss_end = .;

    /DISCARD/ : { *(.riscv.attributes) *(.comment) *(.note*) *(.eh_frame*) }
}
