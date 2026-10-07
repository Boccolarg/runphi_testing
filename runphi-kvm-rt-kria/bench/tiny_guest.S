/*
 * tiny_guest.S - the smallest guests that run: each writes a line to the
 * QEMU virt PL011 (0x09000000), does one thing, writes another line and
 * powers the VM off through PSCI SYSTEM_OFF (HVC, handled by KVM). Used by
 * order_probe.py (variants qemu_tiny*) to find which part of a guest's run
 * leaves the host slower under tlb_shootdown. MODE:
 *   0  nothing (tiny_guest.elf)
 *   1  spin for 40 s, MMU off (tiny_spin.elf)
 *   2  write one word to every 4 KB page of the guest RAM above this image,
 *      MMU off: KVM maps all of it at stage 2 (tiny_touch.elf)
 *   3  MMU and caches on (identity map), then spin for 40 s (tiny_mmu_spin.elf)
 *   4  MMU and caches on, then for 40 s: read 16 pages and invalidate them
 *      by VA, broadcast (TLBI VAE1IS; DSB ISH), as a kernel unmapping pages
 *      does (tiny_mmu_tlbi.elf)
 *   5  only the TLBI VMALLE1 that modes 3 and 4 do before turning the MMU
 *      on (broadcast by KVM's HCR_EL2.FB, with the guest's VMID), MMU off,
 *      then spin for 40 s (tiny_tlbi_only.elf)
 *   6  mode 3 without that TLBI (tiny_mmu_noflush.elf)
 *   7  mode 6 with the caches off: SCTLR_EL1.M only (tiny_mmu_nocache.elf)
 * An exception prints FAULT and powers off.
 *
 * Build on the workstation and copy to /root/rtbench/bin/ on the board:
 *   aarch64-linux-gnu-gcc -nostdlib -static -Wl,-Ttext=0x40400000 \
 *       -Wl,-z,max-page-size=0x1000 -Wl,--build-id=none -DMODE=<n> \
 *       -o <name>.elf bench/tiny_guest.S
 * (linked 4 MB into the guest RAM, above the device tree QEMU puts at its start)
 */
#ifndef MODE
#define MODE 0
#endif
#define SECONDS 40

	.text
	.globl	_start
_start:
	adr	x0, vectors
	msr	vbar_el1, x0
	isb
	adr	x0, msg_start
	bl	puts
#if MODE != 0 && MODE != 2
	mrs	x19, cntfrq_el0		/* x19 = deadline in counter ticks */
	mov	x20, #SECONDS
	mul	x19, x19, x20
	mrs	x20, cntvct_el0
	add	x19, x19, x20
#endif
#if MODE == 3 || MODE == 4 || MODE == 6 || MODE == 7
	bl	mmu_on
#endif
#if MODE == 5
	tlbi	vmalle1
	dsb	ish
	isb
#endif
#if MODE == 1 || MODE == 3 || MODE >= 5
1:	mrs	x20, cntvct_el0
	cmp	x20, x19
	b.lo	1b
#elif MODE == 2
	movz	x1, #0x4050, lsl #16	/* above this image ... */
	movz	x2, #0x8000, lsl #16	/* ... to the end of the 1 GB */
1:	str	xzr, [x1]
	add	x1, x1, #4096
	cmp	x1, x2
	b.lo	1b
#elif MODE == 4
1:	movz	x1, #0x4050, lsl #16
	mov	x2, #16
2:	ldr	x3, [x1]
	lsr	x4, x1, #12		/* VA[55:12], ASID 0 */
	tlbi	vae1is, x4
	add	x1, x1, #4096
	subs	x2, x2, #1
	b.ne	2b
	dsb	ish
	isb
	mrs	x20, cntvct_el0
	cmp	x20, x19
	b.lo	1b
#endif
#if MODE != 0
	adr	x0, msg_end
	bl	puts
#endif
off:	movz	w0, #0x0008
	movk	w0, #0x8400, lsl #16	/* PSCI SYSTEM_OFF */
	hvc	#0
3:	wfi
	b	3b

puts:	/* x0: NUL-terminated string; clobbers x0-x2 */
	movz	x1, #0x0900, lsl #16	/* PL011 data register */
1:	ldrb	w2, [x0], #1
	cbz	w2, 2f
	str	w2, [x1]
	b	1b
2:	ret

mmu_on:	/* identity map: 0-1 GB Device-nGnRnE, 1-2 GB Normal WB (the RAM) */
	movz	x0, #0xff00		/* MAIR: attr0 Device-nGnRnE, attr1 Normal WB */
	msr	mair_el1, x0
	movz	x0, #0x3519		/* TCR: T0SZ 25, WBWA inner shareable walks, */
	movk	x0, #0x0080, lsl #16	/* 4 KB granule, no TTBR1 walks, */
	movk	x0, #0x0002, lsl #32	/* 40-bit PA */
	msr	tcr_el1, x0
	adr	x0, pgtable
	msr	ttbr0_el1, x0
	isb
#if MODE != 6 && MODE != 7
	tlbi	vmalle1
	dsb	ish
	isb
#endif
	mrs	x0, sctlr_el1
#if MODE == 7
	movz	x1, #0x0001		/* M */
#else
	movz	x1, #0x1005		/* I, C, M */
#endif
	orr	x0, x0, x1
	msr	sctlr_el1, x0
	isb
	ret

fault:	adr	x0, msg_fault
	bl	puts
	b	off

msg_start:	.asciz	"TINY GUEST\n"
msg_end:	.asciz	"TINY END\n"
msg_fault:	.asciz	"FAULT\n"

	.balign	2048
vectors:
	.rept	16
	b	fault
	.balign	128
	.endr

	.data
	.balign	4096
pgtable:	/* level 1, 1 GB blocks */
	.quad	0x0060000000000401	/* 0x00000000: Device, AF, PXN, UXN */
	.quad	0x0000000040000705	/* 0x40000000: Normal WB, inner shareable, AF */
	.fill	510, 8, 0
