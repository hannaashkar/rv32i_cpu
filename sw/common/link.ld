/* Minimal linker script: bare-metal program in imem, entry at address 0.
   The core has separate instruction/data memories (Harvard); data sections
   are not supported yet — assembly tests keep everything in registers. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;
    .text : { *(.text*) }
    /DISCARD/ : { *(.riscv.attributes) *(.comment) *(.note*) }
}
