/*
 * J1 (iPad3,1 / A5X) RAM loader, linked at 0x80000000. iBEC's raw-go
 * `go` enters it with blx, in ARM state, with iBoot's MMU still on.
 *
 * Bundle layouts:
 *   Image   [this loader][pad][header at 0x7ff0][Image at 0x80008000][DTB]
 *   zImage  [this loader][pad to 0x8000][zImage+dtb at 0x80008000]
 *
 * The Image layout is the default (scripts/build-staging.sh). Its header,
 * the 16 bytes before the kernel, is "J1IM", the DTB's offset from
 * 0x80008000 and its size. The kernel Image needs no decompressor, so
 * nothing below depends on how the kernel was compiled: the loader
 * enters it by the ordinary ARM boot protocol (MMU and D-cache off,
 * r0 = 0, r1 = ~0, r2 = the DTB). The DTB is copied to 0x84000000 first,
 * clear of the kernel's BSS, which starts where the Image ends.
 *
 * Without the header it is the zImage layout, and the rest of this
 * comment applies.
 *
 * This is the stripped loader: no drawing, only what the boot needs.
 * j1_linux_boot.S is the debug loader it came from, and still paints
 * progress marks on the panel.
 *
 * _start stops the watchdog, finds the appended DTB, cleans L1 and the
 * PL310, turns the MMU and caches off, and enters the zImage. Four
 * workarounds are planted in the relocated decompressor:
 *
 *   f  cache_on's SCTLR write. Enabling the MMU there never reached the
 *      next instruction, so M and C are cleared from the value written.
 *   h  decompress_kernel entry. r8 is not the DTB here. Copy the DTB to
 *      0x84000000 so __enter_kernel can hand that copy over (above the
 *      relocated zImage, which reaches ~0x831c0000 with a 16 MB image).
 *   n  do_decompress entry. Identity-map DRAM and turn the MMU and both
 *      caches on for inflate, after cleaning L1 and L2. Without the clean,
 *      cached reads saw stale staging bytes and inflate stalled.
 *   k  decompress_kernel returned. The VA clean walk that follows never
 *      came back with the D-cache off. Clean L1 and L2 here, turn the MMU
 *      and caches off, set the Cortex-A9 errata bits the kernel would only
 *      set after paging_init, and go to __enter_kernel with r8 = DTB.
 *
 * Sites are offsets from the relocated `restart`. build-staging.sh checks
 * the zImage words at each of them. Nothing here depends on the kernel
 * Image, only on the decompressor, so kernel rebuilds keep working.
 */
	.arch	armv7-a
	.syntax	unified
	.arm

	.equ	KERNEL_ENTRY,	0x80008000
	/* mov pc, r0 at the end of the relocation copy. r0 = new restart. */
	.equ	INSN_D,		0x80009224
	.equ	DELTA_SCTLR,	0x45c
	.equ	DELTA_DECOMP,	0xa30
	.equ	DELTA_ENTER,	0x8ec
	.equ	DELTA_POSTRET,	0x1fc
	.equ	DELTA_DODEC,	0x2f5c
	.equ	PD_BASE,	0x84010000
	.equ	DTB_COPY,	0x84000000
	.equ	SCAN_END,	0x82008000
	.equ	IMAGE_HDR,	0x80007ff0
	/* "J1IM" as a little-endian word */
	.equ	IMAGE_MAGIC,	0x4d49314a
	/* Bytes d0 0d fe ed, the FDT magic, as a little-endian word. */
	.equ	FDT_MAGIC_LE,	0xedfe0dd0
	/*
	 * iBoot's MMU is still on at entry. This is the address that mapping
	 * uses; the physical one is 0x30000000 higher. Zeroing the block
	 * disarms the reset.
	 */
	.equ	WDT_BASE,	0x0F103020
	.equ	PL310_BASE,	0x3e000000
	.equ	STACK_TOP,	0x80007ff0
	.global	SAFE_STACK
	.equ	SAFE_STACK,	0x80007fe0


/*
 * Optional stage bands, built only with J1_MARKS=1 (build-loader.sh
 * passes it through). Band n is rows 96n..96n+63 of the scanout, painted
 * white with plain physical stores, so it is only used with the MMU off.
 * 1 _start done, 2 hook_d, 3 hook_f, 4 hook_h, 5 hook_n, 6 hook_k.
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
	.global	dtb_phys
	.global	find_dtb
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
	ldr	r0, =IMAGE_HDR
	ldr	r1, [r0]
	ldr	r2, =IMAGE_MAGIC
	cmp	r1, r2
	beq	enter_image
	bl	find_dtb

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

	band	1
	ldr	r0, =held_dtb
	str	r4, [r0]
	b	enter_linux

hang:
	wfi
	b	hang

	.ltorg

/*
 * The Image layout. r0 = the header. Check the DTB, copy it to DTB_COPY,
 * turn the MMU and caches off as for the zImage, set the errata bits and
 * enter the kernel.
 */
enter_image:
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
.img_copy_dtb:
	ldr	r3, [r4], #4
	str	r3, [r1], #4
	subs	r2, r2, #4
	bne	.img_copy_dtb
	dsb
	bl	l2x0_flush_all

	bl	a9_errata
	band	1
	mov	r0, #0
	mvn	r1, #0
	ldr	r2, =DTB_COPY
	ldr	r3, =KERNEL_ENTRY
	bx	r3

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

/* Catch the end of the relocation copy, then enter the zImage. */
enter_linux:
	ldr	r0, =INSN_D
	ldr	r1, =hook_d
	ldr	r2, =saved_d
	bl	plant_branch
	ldr	r3, =INSN_D
	bl	sync_insn
	mov	r0, #0
	mvn	r1, #0
	mov	r2, r4
	ldr	r3, =KERNEL_ENTRY
	bx	r3

	.ltorg

/* r0 = site, r1 = hook, r2 = saved-word pointer. Preserves r4. */
plant_branch:
	ldr	r3, [r0]
	str	r3, [r2]
	sub	r3, r1, r0
	sub	r3, r3, #8
	asr	r3, r3, #2
	bic	r3, r3, #0xff000000
	orr	r3, r3, #0xea000000
	str	r3, [r0]
	bx	lr

/* Same, but leave the site alone when the B cannot reach.
   A miss stores 0 through r2. */
plant_branch_checked:
	push	{r0, lr}
	sub	r3, r1, r0
	sub	r3, r3, #8
	cmp	r3, #0x02000000
	bge	.noplant
	cmn	r3, #0x02000000
	blt	.noplant
	pop	{r0, lr}
	b	plant_branch
.noplant:
	mov	r3, #0
	str	r3, [r2]
	pop	{r0, pc}

/* Make a store to an instruction visible to the fetcher. r3 = address.
   With the MMU off, also drop the PL310 line, or a later write-allocate
   of that line revives the old bytes. Clobbers r0. */
sync_insn:
	push	{r3, lr}
	mrc	p15, 0, r0, c1, c0, 0
	tst	r0, #1
	bleq	l2x0_inv_pa
	mrc	p15, 0, r0, c1, c0, 0
	tst	r0, #(1 << 2)
	beq	.sync_i
	mcr	p15, 0, r3, c7, c11, 1	/* DCCMVAU */
.sync_i:
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	/* ICIALLU */
	mcr	p15, 0, r0, c7, c5, 6	/* BPIALL */
	dsb
	isb
	pop	{r3, pc}

/* Plant hook at saved_r0 + delta. A B that cannot reach is skipped. */
.macro reloc_plant delta, hook, live, saved
	ldr	r0, =saved_r0
	ldr	r0, [r0]
	ldr	r1, =\delta
	add	r0, r0, r1
	ldr	r3, =\live
	str	r0, [r3]
	push	{r0}
	ldr	r1, =\hook
	ldr	r2, =\saved
	bl	plant_branch_checked
	pop	{r3}
	ldr	r2, =\saved
	ldr	r2, [r2]
	cmp	r2, #0
	blne	sync_insn
.endm

/* Relocation copy finished. r0 is the relocated restart. */
hook_d:
	ldr	r2, =saved_sp
	str	sp, [r2]
	ldr	r2, =saved_r0
	str	r0, [r2]
	ldr	sp, =SAFE_STACK
	band	2
	ldr	r3, =INSN_D
	ldr	r1, =saved_d
	ldr	r1, [r1]
	str	r1, [r3]
	bl	sync_insn
	reloc_plant DELTA_SCTLR, hook_f, live_f, saved_f
	reloc_plant DELTA_DECOMP, hook_h, live_h, saved_h
	reloc_plant DELTA_POSTRET, hook_k, live_k, saved_k
	reloc_plant DELTA_DODEC, hook_n, live_n, saved_n
	ldr	r2, =saved_sp
	ldr	sp, [r2]
	ldr	r0, =saved_r0
	ldr	r0, [r0]
	ldr	r3, =INSN_D
	bx	r3

	.ltorg

/* cache_on is about to write SCTLR. r0 is the value, r12 its return.
   Write it with the MMU and D-cache bits clear. */
hook_f:
	ldr	r2, =saved_sp
	str	sp, [r2]
	ldr	r2, =saved_sctlr
	str	r0, [r2]
	ldr	r2, =saved_ip
	str	r12, [r2]
	ldr	sp, =SAFE_STACK
	band	3
	ldr	r3, =live_f
	ldr	r3, [r3]
	ldr	r1, =saved_f
	ldr	r1, [r1]
	str	r1, [r3]
	bl	sync_insn
	ldr	r2, =saved_sp
	ldr	sp, [r2]
	ldr	r2, =saved_ip
	ldr	r12, [r2]
	ldr	r0, =saved_sctlr
	ldr	r0, [r0]
	bic	r0, r0, #5
	ldr	r3, =live_f
	ldr	r3, [r3]
	bx	r3

/* decompress_kernel entry. Copy the DTB found before the jump to
   DTB_COPY, its own totalsize long. Keep the call arguments and lr. */
hook_h:
	push	{r0, r1, r2, r3}
	ldr	r2, =saved_lr
	str	lr, [r2]
	ldr	r2, =saved_sp
	str	sp, [r2]
	ldr	sp, =SAFE_STACK
	band	4
	ldr	r0, =held_dtb
	ldr	r0, [r0]
	ldr	r3, [r0]
	ldr	r1, =FDT_MAGIC_LE
	cmp	r3, r1
	bne	.dtb_done
	ldr	r2, [r0, #4]
	rev	r2, r2
	add	r2, r2, #3
	bic	r2, r2, #3
	ldr	r1, =DTB_COPY
.copy_dtb:
	ldr	r3, [r0], #4
	str	r3, [r1], #4
	subs	r2, r2, #4
	bne	.copy_dtb
	ldr	r3, =dtb_copied
	mov	r0, #1
	str	r0, [r3]
.dtb_done:
	ldr	r3, =live_h
	ldr	r3, [r3]
	ldr	r1, =saved_h
	ldr	r1, [r1]
	str	r1, [r3]
	bl	sync_insn
	ldr	r2, =saved_sp
	ldr	sp, [r2]
	pop	{r0, r1, r2, r3}
	ldr	r12, =saved_lr
	ldr	lr, [r12]
	ldr	r12, =live_h
	ldr	r12, [r12]
	bx	r12

	.ltorg

/* decompress_kernel returned. Clean L1, turn the MMU and caches off,
   clean L2, then __enter_kernel with r8 = the DTB copy. r4 (the kernel
   entry) and r7 (the arch number) stay. */
hook_k:
	ldr	r2, =saved_sp
	str	sp, [r2]
	ldr	sp, =SAFE_STACK
	bl	v7_flush_dcache_all
	dsb
	/* PL310 is outside the inflate map. The MMU goes off before L2. */
	mrc	p15, 0, r0, c1, c0, 0
	bic	r0, r0, #0x1000
	bic	r0, r0, #5
	mcr	p15, 0, r0, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 4	/* ISB */
	isb
	mcr	p15, 0, r0, c7, c5, 0	/* ICIALLU */
	mcr	p15, 0, r0, c7, c5, 6	/* BPIALL */
	dsb
	isb
	bl	l2x0_flush_all
	band	6
	/*
	 * Cortex-A9 r2pN errata 743622 (store-buffer hazard checking can
	 * corrupt data; diagnostic bit 6) and 751472 (interrupted ICIALLUIS
	 * may never complete; bit 11). The kernel only sets these in
	 * init_early, after paging_init has already done its page-table
	 * writes, and paging_init dies without them. Only secure code may
	 * write the diagnostic register, and this loader runs secure.
	 */
	mrc	p15, 0, r0, c0, c0, 0	/* MIDR */
	ldr	r1, =0xff0ffff0
	and	r1, r0, r1
	ldr	r2, =0x410fc090		/* ARM Cortex-A9, any variant/rev */
	cmp	r1, r2
	bne	.no_errata
	ubfx	r1, r0, #20, #4		/* variant */
	mrc	p15, 0, r0, c15, c0, 1
	cmp	r1, #2
	orreq	r0, r0, #(1 << 6)
	cmp	r1, #3
	orrlo	r0, r0, #(1 << 11)
	mcr	p15, 0, r0, c15, c0, 1
	isb
.no_errata:
	ldr	r2, =saved_sp
	ldr	sp, [r2]
	ldr	r3, =dtb_copied
	ldr	r3, [r3]
	cmp	r3, #0
	ldrne	r8, =DTB_COPY
	ldr	r0, =saved_r0
	ldr	r0, [r0]
	ldr	r1, =DELTA_ENTER
	add	r0, r0, r1
	bx	r0

/* do_decompress entry. Its first instruction pushes lr, so put the
   caller's lr back before resuming there. */
hook_n:
	push	{r0, r1, r2, r3}
	ldr	r2, =saved_lr
	str	lr, [r2]
	ldr	r2, =saved_sp
	str	sp, [r2]
	ldr	sp, =SAFE_STACK
	band	5
	bl	ram_cache_on
	ldr	r3, =live_n
	ldr	r3, [r3]
	ldr	r1, =saved_n
	ldr	r1, [r1]
	str	r1, [r3]
	bl	sync_insn
	ldr	r2, =saved_sp
	ldr	sp, [r2]
	pop	{r0, r1, r2, r3}
	ldr	r12, =saved_lr
	ldr	lr, [r12]
	ldr	r12, =live_n
	ldr	r12, [r12]
	bx	r12

	.ltorg

/* Identity-map the 1GB of DRAM write-back and turn the MMU and both
   caches on. A fault while this is on hangs: the vectors are not mapped.
   Preserves r4-r11 and lr. */
ram_cache_on:
	push	{r4, r5, r6, r7, r8, r9, r10, r11, lr}
	ldr	r0, =PD_BASE
	mov	r1, #4096
	mov	r2, #0
.pd_clear:
	str	r2, [r0], #4
	subs	r1, r1, #1
	bne	.pd_clear
	ldr	r0, =PD_BASE
	ldr	r1, =0x80000000
	add	r0, r0, r1, lsr #18
	mov	r2, #1024
.pd_map:
	orr	r3, r1, #0xc00
	orr	r3, r3, #0x0e
	str	r3, [r0], #4
	add	r1, r1, #0x100000
	subs	r2, r2, #1
	bne	.pd_map
	/* PL310 registers, strongly ordered and XN. */
	ldr	r0, =PD_BASE
	ldr	r3, =(PL310_BASE | 0xc12)
	str	r3, [r0, #(PL310_BASE >> 18)]
	/* Caches are still off. Drop anything L1 or L2 kept from before
	   the relocation, or the first cached reads see old staging bytes. */
	bl	v7_flush_dcache_all
	bl	l2x0_flush_all
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0
	mcr	p15, 0, r0, c8, c7, 0
	mcr	p15, 0, r0, c7, c5, 6
	dsb
	isb
	mcr	p15, 0, r0, c2, c0, 2
	ldr	r0, =PD_BASE
	mcr	p15, 0, r0, c2, c0, 0
	mov	r0, #3
	mcr	p15, 0, r0, c3, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	bic	r0, r0, #(1 << 28)
	bic	r0, r0, #2
	orr	r0, r0, #0x1000
	orr	r0, r0, #5
	orr	r0, r0, #(1 << 22)
	mcr	p15, 0, r0, c1, c0, 0
	mrc	p15, 0, r0, c1, c0, 0
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 4
	isb
	pop	{r4, r5, r6, r7, r8, r9, r10, r11, pc}

	.ltorg

/*
 * r4 = DTB physical address. dtb_phys may be patched by the staging step.
 * Zero means scan [0x80008000, SCAN_END) for the FDT magic and keep the
 * last blob whose big-endian totalsize is 64 bytes to 1 MiB and fits the
 * window. Compressed-data hits have absurd sizes and are skipped. No
 * blob: hang, and do not jump.
 */
find_dtb:
	ldr	r4, dtb_phys
	cmp	r4, #0
	bxne	lr
	ldr	r0, =KERNEL_ENTRY
	ldr	r1, =SCAN_END
	ldr	r2, =FDT_MAGIC_LE
	mov	r4, #0
.Lscan:
	cmp	r0, r1
	bhs	.Lscan_done
	ldr	r3, [r0]
	cmp	r3, r2
	bne	.Lnext
	ldr	r3, [r0, #4]
	rev	r3, r3
	cmp	r3, #0x40
	blo	.Lnext
	cmp	r3, #0x00100000
	bhi	.Lnext
	add	r5, r0, r3
	cmp	r5, r1
	bhi	.Lnext
	mov	r4, r0
.Lnext:
	add	r0, r0, #4
	b	.Lscan
.Lscan_done:
	cmp	r4, #0
	bxne	lr
	b	hang

	.align	2
dtb_phys:
	.word	0
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

/* r3 = physical address. MMU is off. Clean and drop one PL310 line.
   Preserves r3. */
l2x0_inv_pa:
	push	{r0, r1, r2, lr}
	dsb
	mov	r0, #PL310_BASE
	ldr	r1, [r0, #0x100]
	tst	r1, #1
	beq	.Linv_done
	bic	r2, r3, #31
	str	r2, [r0, #0x7f0]
	mov	r1, #0
	str	r1, [r0, #0x730]
.Linv_wait:
	ldr	r1, [r0, #0x730]
	tst	r1, #1
	bne	.Linv_wait
.Linv_done:
	pop	{r0, r1, r2, pc}

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
held_dtb:	.word	0
dtb_copied:	.word	0
saved_r0:	.word	0
saved_sp:	.word	0
saved_lr:	.word	0
saved_ip:	.word	0
saved_sctlr:	.word	0
saved_d:	.word	0
saved_f:	.word	0
live_f:		.word	0
saved_h:	.word	0
live_h:		.word	0
saved_k:	.word	0
live_k:		.word	0
saved_n:	.word	0
live_n:		.word	0
