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

    .rodata : { *(.rodata*) } > DMEM

    .data : { *(.data*) } > DMEM

    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.srodata*)
        *(.sdata*)
    } > DMEM

    . = ALIGN(4);
    __bss_start = .;
    .sbss : { *(.sbss*) *(.scommon) } > DMEM
    .bss  : { *(.bss*)  *(COMMON)   } > DMEM
    . = ALIGN(4);
    __bss_end = .;

    /DISCARD/ : { *(.riscv.attributes) *(.comment) *(.note*) *(.eh_frame*) }
}
