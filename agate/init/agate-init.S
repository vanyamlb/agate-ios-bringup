// agate first userspace program (PID 1 from the mockfs RAM disk).
//
// The RAM disk *is* this executable: mockfs serves it as /sbin/launchd.
// It opens /dev/console, prints a banner with its PID, then prints a
// counter every 5 seconds forever (init exiting would panic the kernel).
//
// Wrapped into a static, ad-hoc signed Mach-O by ios-topaz tools/mkinit.py,
// so: one __text section, PC-relative references only, no writable data.
// Raw XNU syscalls: number in x16, svc #0x80, carry set on error.
// Note: ';' starts a comment in Apple arm64 assembly.

#define SYS_write	4
#define SYS_open	5
#define SYS_getpid	20
#define SYS_select	93
#define O_RDWR		2

	.text
	.globl	_start
	.p2align 2
_start:
	// sp may be misaligned at entry of a static binary: align it.
	mov	x9, sp
	and	x9, x9, #~15
	mov	sp, x9
	sub	sp, sp, #32

	adr	x0, path
	mov	x1, #O_RDWR
	mov	x2, #0
	mov	x16, #SYS_open
	svc	#0x80
	b.cs	hang
	mov	x19, x0

	adr	x1, banner
	adr	x2, banner_pid
	sub	x2, x2, x1
	bl	write_console

	mov	x16, #SYS_getpid
	svc	#0x80
	add	w0, w0, #'0'
	strb	w0, [sp]
	mov	x1, sp
	mov	x2, #1
	bl	write_console

	adr	x1, banner_pid
	adr	x2, alive
	sub	x2, x2, x1
	bl	write_console

	mov	x20, #0			// counter 0..99, wraps
tick:
	mov	x0, #0
	mov	x1, #0
	mov	x2, #0
	mov	x3, #0
	adr	x4, five_sec
	mov	x16, #SYS_select
	svc	#0x80

	add	x20, x20, #1
	cmp	x20, #100
	csel	x20, xzr, x20, eq
	mov	x9, #10
	udiv	x10, x20, x9		// tens
	msub	x11, x10, x9, x20	// ones
	add	w10, w10, #'0'
	add	w11, w11, #'0'

	adr	x1, alive
	adr	x2, alive_end
	sub	x2, x2, x1
	bl	write_console
	strb	w10, [sp]
	strb	w11, [sp, #1]
	mov	w12, #'\n'
	strb	w12, [sp, #2]
	mov	x1, sp
	mov	x2, #3
	bl	write_console
	b	tick

// write(x19, x1, x2)
write_console:
	mov	x0, x19
	mov	x16, #SYS_write
	svc	#0x80
	ret

hang:
	b	hang

	.p2align 3
five_sec:
	.quad	5			// tv_sec
	.quad	0			// tv_usec
path:
	.asciz	"/dev/console"
banner:
	.ascii	"\n*** AGATE: iOS userspace on Xiaomi 11T, init running as PID "
banner_pid:
	.ascii	" ***\n"
alive:
	.ascii	"AGATE init: alive, tick "
alive_end:
