/* =============================================================================
   link.ld — bare-metal layout for the Harvard rv32i_cpu core

   imem (instructions) and dmem (data) are physically separate memories:
   fetches only ever see imem, loads/stores only ever see dmem (or MMIO at
   0x4xxxxxxx). Both memories ignore high address bits (index is a bit
   slice, so addresses alias), which makes the VMAs below pure convention —
   chosen so each region starts at word 0 of its memory:

     0x00000000  .text          -> imem image  (<prog>.text.hex, +imem=)
     0x10000000  data sections  -> dmem image  (<prog>.data.hex, +dmem=)
                 (0x10000000 hits dmem word 0: its index bits are all zero)
     0x40000000  MMIO           -> LEDs / switches / sim-exit (never RAM)

   Sizes are the SIM_BIG_MEM simulation sizes (256 KB each) used for
   benchmarks; the FPGA build's memories are smaller (4 KB imem / 1 KB
   dmem) — an FPGA-targeted C program must fit those or get its own script.

   The .dmem_origin sentinel (4 bytes, emitted by crt0.S) pins the start of
   the extracted data image to exactly 0x10000000: objcopy -O binary starts
   its output at the first present section, so without the sentinel a
   program with an empty .rodata would have its whole data image shifted
   down and every global would load garbage.

   Assembly tests (sw/tests/*.S) keep using this script unchanged — they
   emit only .text, so their whole-file binary is identical to before.
============================================================================= */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 256K
    DMEM (rw) : ORIGIN = 0x10000000, LENGTH = 256K
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

    /* Small data grouped so one gp anchor covers it all: RISC-V linker
       relaxation then turns lui+lw pairs into single gp-relative loads.
       gp sits 0x800 past the section start so its signed 12-bit offset
       reaches 4 KB of small data/bss. */
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
