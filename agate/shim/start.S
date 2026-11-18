/*
 * agate XNU shim: entry points.
 *
 * Layout inside the decompressed Image (LK loads it at 0x40080000):
 *   +0x00000  ARM64 Image header (code0 branches to +0x1000)
 *   +0x01000  this shim (_start)            < SHIM_MAX
 *   +0x0b000  kicker stack (top at +0x10000)
 *   +0x10000  boot CPU stack (top at +0x1f000)
 *   +0x20000  SWEETXNU payload (agate/tools/pack_xnu.py)
 * Everything is PC-relative; LK enters with the MMU off, x0 = DTB.
 */
	.section .text.start, "ax"
	.global _start
_start:
	msr	daifset, #0xf
	mov	x19, x0			/* DTB */
	adr	x1, _start
	mov	x2, #0x1e000		/* stack top = Image + 0x1f000 */
	add	x1, x1, x2
	mov	sp, x1
	mov	x0, x19
	bl	shim_main
1:	wfi
	b	1b

/*
 * PSCI CPU_ON target for the frame kicker (an A78 core that XNU never
 * uses). Entered with the MMU off; x0 = context id (unused).
 */
	.global kicker_entry
kicker_entry:
	msr	daifset, #0xf
	adr	x1, _start
	mov	x2, #0xf000		/* stack top = Image + 0x10000 */
	add	x1, x1, x2
	mov	sp, x1
	bl	kicker_main
2:	wfi
	b	2b
