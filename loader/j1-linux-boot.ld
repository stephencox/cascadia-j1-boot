/*
 * J1 RAM loader at iBEC's load address. The zImage sits at 0x80008000.
 * The stack lives at 0x80007ff0, in the pad, and the image has to end
 * by 0x80007f60 so the stack keeps 128 bytes clear of the loader.
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
