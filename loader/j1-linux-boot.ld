/*
 * J1 RAM loader at iBEC's load address. The kernel Image sits at
 * 0x80008000, behind a 16-byte header at 0x80007ff0. The stack grows down
 * from 0x80007fe0, in the pad, and the loader has to end by 0x80007f60 so
 * the stack keeps 128 bytes clear of it.
 */
ENTRY(_start)

SECTIONS
{
	. = 0x80000000;

	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.*)
		. = ALIGN(4);
		_end = .;
	}

	ASSERT(_end <= 0x80007f60, "loader overlaps the stack at 0x80007ff0")

	.ARM.attributes 0 : { *(.ARM.attributes) }

	/DISCARD/ : {
		*(.comment)
		*(.note*)
		*(.eh_frame*)
		*(.ARM.exidx*)
	}
}
