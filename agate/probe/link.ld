/* Linked at the payload slot (Image + 0x1000); the code is PC-relative. */
ENTRY(_start)
SECTIONS
{
	. = 0x40081000;
	.text : {
		*(.text.start)
		*(.text .text.*)
		*(.rodata .rodata.*)
	}
	.data : { *(.data .data.*) }
	.bss : { *(.bss .bss.* COMMON) }
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
ASSERT(SIZEOF(.data) == 0, "probe must not use .data")
ASSERT(SIZEOF(.bss) == 0, "probe must not use .bss")
