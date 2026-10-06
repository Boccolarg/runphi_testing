/*
 * tiny_guest.S - the smallest guest that runs: it writes one line to the
 * QEMU virt PL011 (0x09000000) and powers the VM off through PSCI
 * SYSTEM_OFF (HVC, handled by KVM), a few dozen instructions in all, with
 * the MMU off. Used by order_probe.py (variant qemu_tiny) to tell KVM's own
 * entry into a guest from what a guest kernel does once it runs.
 *
 * Build on the workstation and copy to /root/rtbench/bin/ on the board:
 *   aarch64-linux-gnu-gcc -nostdlib -static -Wl,-Ttext=0x40400000 \
 *       -Wl,-z,max-page-size=0x1000 -Wl,--build-id=none -o tiny_guest.elf bench/tiny_guest.S
 * (linked 4 MB into the guest RAM, above the device tree QEMU puts at its start)
 */
	.text
	.globl	_start
_start:
	movz	x1, #0x0900, lsl #16	/* PL011 data register */
	adr	x2, msg
1:	ldrb	w3, [x2], #1
	cbz	w3, 2f
	str	w3, [x1]
	b	1b
2:	movz	w0, #0x0008
	movk	w0, #0x8400, lsl #16	/* PSCI SYSTEM_OFF */
	hvc	#0
3:	wfi
	b	3b

msg:	.asciz	"TINY GUEST\n"
