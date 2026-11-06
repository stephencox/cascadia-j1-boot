/*
 * J1 (iPad3,1 / A5X) RAM loader, linked at 0x80000000. iBEC's raw-go
 * `go` enters it with blx, in ARM state, with iBoot's MMU still on.
 *
 * Staging layout (scripts/build-staging.sh):
 *
 *   [this loader][pad][header at 0x7ff0][kernel Image at 0x80008000][DTB]
 *
 * The header, the 16 bytes before the kernel, is "J1IM", the DTB's offset
 * from 0x80008000 and its size. The loader stops the watchdog, cleans L1
 * and the PL310, turns the MMU and caches off, copies the DTB to
 * 0x84000000 (clear of the kernel's BSS, which starts where the Image
 * ends), sets two Cortex-A9 errata bits, and enters the Image by the
 * ordinary ARM boot protocol: r0 = 0, r1 = ~0, r2 = the DTB. No
 * decompressor runs, so nothing here depends on how the kernel was built.
 */
	.arch	armv7-a
	.syntax	unified
	.arm

	.equ	KERNEL_ENTRY,	0x80008000
	.equ	IMAGE_HDR,	0x80007ff0
	/* "J1IM" as a little-endian word */
	.equ	IMAGE_MAGIC,	0x4d49314a
	.equ	DTB_COPY,	0x84000000
	/* Bytes d0 0d fe ed, the FDT magic, as a little-endian word. */
	.equ	FDT_MAGIC_LE,	0xedfe0dd0
	/*
	 * iBoot's MMU is still on at entry. This is the address that mapping
	 * uses; the physical one is 0x30000000 higher. Zeroing the block
	 * disarms the reset.
	 */
	.equ	WDT_BASE,	0x0F103020
	.equ	PL310_BASE,	0x3e000000
	.equ	STACK_TOP,	0x80007fe0


/*
 * Optional stage bands, built only with J1_MARKS=1 (build-loader.sh
 * passes it through). Band n is rows 96n..96n+63 of the scanout, painted
 * white with plain physical stores, so it is only used with the MMU off.
 * 1: about to enter the kernel.
 */
	.equ	FB_BASE,	0xbdb00000
.macro band n
.ifdef J1_MARKS
	push	{r0, r1, r2, lr}
	mov	r0, #\n
	bl	paint_band
	pop	{r0, r1, r2, lr}
.endif
.endm

	.section .text.start, "ax"
	.global	_start
_start:
	cpsid	if

	/* A second entry would run on top of a half-started kernel. */
	ldr	r2, =boot_pass
	ldr	r1, [r2]
	cmp	r1, #0
	bne	hang
	mov	r1, #1
	str	r1, [r2]
	dsb

	msr	cpsr_c, #0xd3
	bl	v7_flush_dcache_all
	dsb
	isb

	ldr	r0, =WDT_BASE
	mov	r1, #0
	str	r1, [r0, #0x00]
	str	r1, [r0, #0x04]
	str	r1, [r0, #0x08]
	str	r1, [r0, #0x0C]

	ldr	sp, =STACK_TOP

	/* The header, and a DTB where it says. Anything else: do not jump. */
	ldr	r0, =IMAGE_HDR
	ldr	r1, [r0]
	ldr	r2, =IMAGE_MAGIC
	cmp	r1, r2
	bne	hang
	ldr	r4, [r0, #4]		/* DTB offset from KERNEL_ENTRY */
	ldr	r1, =KERNEL_ENTRY
	add	r4, r4, r1
	ldr	r3, [r4]
	ldr	r1, =FDT_MAGIC_LE
	cmp	r3, r1
	bne	hang

	bl	v7_flush_dcache_all
	bl	l2x0_flush_all

	mrc	p15, 0, r0, c1, c0, 0
	bic	r0, r0, #(1 << 0)	/* MMU */
	bic	r0, r0, #(1 << 2)	/* D-cache */
	bic	r0, r0, #(1 << 12)	/* I-cache */
	bic	r0, r0, #(1 << 11)	/* branch predictor */
	mcr	p15, 0, r0, c1, c0, 0
	isb
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	/* ICIALLU */
	mcr	p15, 0, r0, c7, c5, 6	/* BPIALL */
	mcr	p15, 0, r0, c8, c7, 0	/* TLBIALL */
	dsb
	isb

	/* totalsize is big-endian at +4, rounded up to a word */
	ldr	r2, [r4, #4]
	rev	r2, r2
	add	r2, r2, #3
	bic	r2, r2, #3
	ldr	r1, =DTB_COPY
.copy_dtb:
	ldr	r3, [r4], #4
	str	r3, [r1], #4
	subs	r2, r2, #4
	bne	.copy_dtb
	dsb
	bl	l2x0_flush_all

	bl	a9_errata
	band	1
	mov	r0, #0
	mvn	r1, #0
	ldr	r2, =DTB_COPY
	ldr	r3, =KERNEL_ENTRY
	bx	r3

hang:
	wfi
	b	hang

	.ltorg

/*
 * Cortex-A9 r2pN errata 743622 (store-buffer hazard checking can corrupt
 * data; diagnostic bit 6) and 751472 (interrupted ICIALLUIS may never
 * complete; bit 11). The kernel only sets these in init_early, after
 * paging_init has already done its page-table writes, and paging_init
 * dies without them. Only secure code may write the diagnostic register,
 * and this loader runs secure. Clobbers r0-r2.
 */
a9_errata:
	mrc	p15, 0, r0, c0, c0, 0	/* MIDR */
	ldr	r1, =0xff0ffff0
	and	r1, r0, r1
	ldr	r2, =0x410fc090		/* ARM Cortex-A9, any variant/rev */
	cmp	r1, r2
	bxne	lr
	ubfx	r1, r0, #20, #4		/* variant */
	mrc	p15, 0, r0, c15, c0, 1
	cmp	r1, #2
	orreq	r0, r0, #(1 << 6)
	cmp	r1, #3
	orrlo	r0, r0, #(1 << 11)
	mcr	p15, 0, r0, c15, c0, 1
	isb
	bx	lr

	.ltorg

/* Clean and invalidate L1 D by set/way, as Linux does on Cortex-A9. */
v7_flush_dcache_all:
	push	{r4-r11, lr}
	dmb
	mrc	p15, 1, r0, c0, c0, 1
	ands	r3, r0, #0x7000000
	lsr	r3, r3, #23
	beq	.Lfinished
	mov	r10, #0
.Lloop_level:
	add	r2, r10, r10, lsr #1
	lsr	r1, r0, r2
	and	r1, r1, #7
	cmp	r1, #2
	blt	.Lskip_level
	mcr	p15, 2, r10, c0, c0, 0
	isb
	mrc	p15, 1, r1, c0, c0, 0
	and	r2, r1, #7
	add	r2, r2, #4
	movw	r4, #0x3ff
	ands	r4, r4, r1, lsr #3
	clz	r5, r4
	movw	r7, #0x7fff
	ands	r7, r7, r1, lsr #13
.Lloop_way:
	mov	r9, r7
.Lloop_set:
	orr	r11, r10, r4, lsl r5
	orr	r11, r11, r9, lsl r2
	mcr	p15, 0, r11, c7, c14, 2
	subs	r9, r9, #1
	bge	.Lloop_set
	subs	r4, r4, #1
	bge	.Lloop_way
.Lskip_level:
	add	r10, r10, #2
	cmp	r3, r10
	bgt	.Lloop_level
.Lfinished:
	mov	r10, #0
	mcr	p15, 2, r10, c0, c0, 0
	dsb
	isb
	pop	{r4-r11, pc}

/* Clean and invalidate every PL310 way, then sync. Skips the poke when
   the cache ID is not an L2x0 or the controller is off. Preserves r4. */
l2x0_flush_all:
	push	{r0, r1, r2, lr}
	ldr	r0, =PL310_BASE
	ldr	r1, [r0]
	lsr	r2, r1, #6
	and	r2, r2, #0x3f
	cmp	r2, #3
	cmpne	r2, #2
	cmpne	r2, #1
	bne	.Ll2_done
	ldr	r1, [r0, #0x100]
	tst	r1, #1
	beq	.Ll2_done
	mov	r1, #0xff00
	orr	r1, r1, #0xff
	str	r1, [r0, #0x7fc]
.Ll2_wait_way:
	ldr	r1, [r0, #0x7fc]
	cmp	r1, #0
	bne	.Ll2_wait_way
	mov	r1, #0
	str	r1, [r0, #0x730]
.Ll2_wait_sync:
	ldr	r1, [r0, #0x730]
	tst	r1, #1
	bne	.Ll2_wait_sync
.Ll2_done:
	dsb
	pop	{r0, r1, r2, pc}

	.ltorg


.ifdef J1_MARKS
/* r0 = band. Clobbers r0-r2. */
paint_band:
	ldr	r1, =FB_BASE
	mov	r2, #(96 * 8192)
	mla	r1, r0, r2, r1
	mov	r2, #(64 * 2048)
	mvn	r0, #0
.pb_loop:
	str	r0, [r1], #4
	subs	r2, r2, #1
	bne	.pb_loop
	dsb
	bx	lr
	.ltorg
.endif

	.align	2
boot_pass:	.word	0
