/*
 * agate display probe: entry.
 *
 * LK jumps here (via the branch at Image+0) with the MMU off, x0 = DTB.
 * Everything is PC-relative, so the probe runs wherever LK loads it.
 * The stack lives 16 MiB above the entry, inside the decompressed kernel
 * slot that LK already reserved for us (the raw Image is ~34 MiB).
 */
	.section .text.start, "ax"
	.global _start
_start:
	msr	daifset, #0xf		/* no interrupts */
	mov	x19, x0			/* DTB */
	adr	x1, _start
	mov	x2, #0x1000000
	add	x1, x1, x2
	and	x1, x1, #~0xf
	mov	sp, x1
	mov	x0, x19
	bl	probe_main
1:	wfi
	b	1b
