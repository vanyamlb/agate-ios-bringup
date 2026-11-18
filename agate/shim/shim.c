/*
 * agate (Xiaomi 11T, MT6893) XNU shim: acts as iBoot for the sweet/ruby XNU.
 *
 * LK runs this from boot_a instead of Linux. It:
 *   1. turns off the TOPRGU watchdog,
 *   2. checks the SWEETXNU payload at Image + 0x20000 (tools/mkpayload.py),
 *   3. moves the visible OVL0 layer 1 to ruby's buffer layout
 *      (0x7cdfc000, pitch 4352) so the ruby early-console patches apply
 *      unchanged; both buffers lie in the framebuffer mblock,
 *   4. starts a frame "kicker" on an A78 core via PSCI CPU_ON: the panel is
 *      DSI command mode and only shows a new frame after mutex0 EN +
 *      DSI_START; the kicker does that ~30 times a second for the life of
 *      the system and blinks a heartbeat square (XNU never uses the A78s),
 *   5. copies the kernel segments, the ADT and boot_args to the kernel RAM
 *      window and jumps to XNU with the MMU off, x0 = boot_args.
 *
 * Writes go only to the framebuffer mblock, to the kernel RAM window
 * (0x140000000..0x1c0000000, checked) and to OVL0 L1 / mutex0 / DSI0 /
 * TOPRGU registers. No storage, PMIC, GPIO or clock access.
 */
#include <stdint.h>
#include "font5x7.h"

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

#define SHIM_VERSION "1"

#define FB_LO 0x7b020000UL
#define FB_HI 0x7d800000UL
#define OLD_FB 0x7ba16000UL /* LK's visible layer (probe 1) */
#define OLD_PITCH 4320u
#define NEW_FB 0x7cdfc000UL /* ruby layout used by patches 0010/0012 */
#define NEW_PITCH 4352u
#define PANEL_W 1080u
#define PANEL_H 2400u

#define KRAM_LO 0x140000000UL /* kernel RAM window allowed for XNU */
#define KRAM_HI 0x1c0000000UL

#define TOPRGU 0x10007000UL
#define DSI0 0x1400e000UL
#define MUTEX 0x14117000UL
#define OVL0 0x14000000UL
#define OVL_L1_PITCH (OVL0 + 0x64)
#define OVL_L1_ADDR (OVL0 + 0xf60)

#define PSCI_CPU_ON 0xc4000003UL
#define PAYLOAD_FROM_START 0x1f000UL /* Image + 0x20000 */

#define COL_FG 0xffffffffu
#define COL_BG 0xff000000u
#define COL_OK 0xff00ff00u
#define COL_ERR 0xffff0000u

extern char _start[];
extern char kicker_entry[];

static inline u32 rd32(u64 a) { return *(volatile u32 *)a; }
static inline void wr32(u64 a, u32 v) { *(volatile u32 *)a = v; }

void *memset(void *d, int c, unsigned long n)
{
	volatile u8 *p = d;
	while (n--)
		*p++ = (u8)c;
	return d;
}

void *memcpy(void *d, const void *s, unsigned long n)
{
	volatile u8 *p = d;
	const u8 *q = s;
	while (n--)
		*p++ = *q++;
	return d;
}

/* ---- timer ---- */

static inline u64 cntpct(void)
{
	u64 v;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

static inline u64 cntfrq(void)
{
	u64 v;
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
	return v ? v : 13000000;
}

static void delay_ms(u32 ms)
{
	u64 end = cntpct() + cntfrq() / 1000 * ms;
	while (cntpct() < end)
		;
}

/* ---- display ---- */

static void kick(void)
{
	for (u32 w = 0; w < 50 && (rd32(DSI0 + 0x0c) & 0x80000000u); w++)
		delay_ms(1);
	wr32(MUTEX + 0x20, 1); /* mutex0 EN */
	wr32(DSI0 + 0x00, 0);
	wr32(DSI0 + 0x00, 1);
}

struct surf {
	u64 base;
	u32 pitch;
};

static int in_fb(u64 a, u64 len)
{
	return a >= FB_LO && a + len >= a && a + len <= FB_HI;
}

static void rect(const struct surf *s, u32 x, u32 y, u32 w, u32 h, u32 c)
{
	for (u32 j = y; j < y + h && j < PANEL_H; j++) {
		u64 row = s->base + (u64)j * s->pitch;
		for (u32 i = x; i < x + w && i < PANEL_W; i++) {
			u64 a = row + (u64)i * 4;
			if (in_fb(a, 4))
				wr32(a, c);
		}
	}
}

#define SCALE 3u
#define CELL_W (6u * SCALE)
#define CELL_H (9u * SCALE)

static int glyph(char ch)
{
	if (ch >= 'a' && ch <= 'z')
		ch = (char)(ch - 32);
	for (int i = 0; font_chars[i]; i++)
		if (font_chars[i] == ch)
			return i;
	return 0;
}

static void draw_str(const struct surf *s, u32 x, u32 y, const char *p, u32 fg)
{
	for (; *p && x + CELL_W <= PANEL_W; p++, x += CELL_W) {
		const unsigned char *g = font_rows[glyph(*p)];
		for (u32 r = 0; r < 9; r++)
			for (u32 c = 0; c < 6; c++) {
				int on = r < 7 && c < 5 && ((g[r] >> (4 - c)) & 1);
				rect(s, x + c * SCALE, y + r * SCALE, SCALE, SCALE,
				    on ? fg : COL_BG);
			}
	}
}

/* ---- console ---- */

#define LLEN 60
#define CON_TOP 150u

struct con {
	struct surf s;
	u32 y;
};

static void con_line(struct con *c, const char *text, u32 fg)
{
	if (c->y + CELL_H > PANEL_H - 100)
		c->y = CON_TOP;
	rect(&c->s, 0, c->y, PANEL_W, CELL_H, COL_BG);
	draw_str(&c->s, 24, c->y, text, fg);
	c->y += CELL_H;
	__asm__ volatile("dsb sy" ::: "memory");
}

static void cat(char *p, const char *s)
{
	int n = 0;

	while (p[n])
		n++;
	while (*s && n < LLEN - 1)
		p[n++] = *s++;
	p[n] = 0;
}

static void cathex(char *p, u64 v, int digits)
{
	char b[17];

	for (int i = digits - 1; i >= 0; i--) {
		u32 d = v & 0xf;
		b[i] = (char)(d < 10 ? '0' + d : 'A' + d - 10);
		v >>= 4;
	}
	b[digits] = 0;
	cat(p, b);
}

static void say(struct con *c, const char *k, u64 v, int digits)
{
	char l[LLEN];

	l[0] = 0;
	cat(l, k);
	if (digits)
		cathex(l, v, digits);
	con_line(c, l, COL_FG);
}

static void fail(struct con *c, const char *why)
{
	con_line(c, "SHIM STOPPED:", COL_ERR);
	con_line(c, why, COL_ERR);
	for (;;) {
		kick();
		delay_ms(100);
	}
}

/* ---- kicker (runs on an A78 core until reset) ---- */

void kicker_main(void)
{
	const struct surf s = { NEW_FB, NEW_PITCH };
	u32 n = 0;

	for (;;) {
		rect(&s, 1000, 60, 48, 48, (n & 16) ? COL_OK : 0xff0000ffu);
		__asm__ volatile("dsb sy" ::: "memory");
		kick();
		delay_ms(33);
		n++;
	}
}

static long psci_cpu_on(u64 mpidr, u64 entry, u64 ctx)
{
	register u64 x0 __asm__("x0") = PSCI_CPU_ON;
	register u64 x1 __asm__("x1") = mpidr;
	register u64 x2 __asm__("x2") = entry;
	register u64 x3 __asm__("x3") = ctx;

	__asm__ volatile("smc #0"
	    : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3)
	    :
	    : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13",
	    "x14", "x15", "x16", "x17", "memory");
	return (long)x0;
}

/* ---- payload / boot_args (tools/mkpayload.py, pexpert boot.h v2) ---- */

#define BOOT_LINE_LENGTH 608
#define PAGE_16K 0x4000UL

struct payload_seg {
	u64 vmaddr, vmsize, file_off, file_size;
};

struct payload {
	char magic[8];
	u32 version, nsegs;
	u64 virt_base, entry_va, adt_off, adt_size, kernel_end;
	u64 phys_base, mem_size;
	char cmdline[BOOT_LINE_LENGTH];
	struct payload_seg segs[];
};

struct boot_video {
	u64 v_baseAddr, v_display, v_rowBytes, v_width, v_height, v_depth;
};

struct boot_args {
	u16 Revision, Version;
	u64 virtBase, physBase, memSize, topOfKernelData;
	struct boot_video Video;
	u32 machineType;
	u64 deviceTreeP;
	u32 deviceTreeLength;
	char CommandLine[BOOT_LINE_LENGTH];
	u64 bootFlags, memSizeActual;
};

_Static_assert(__builtin_offsetof(struct payload, segs) == 0x2a8, "payload layout");
_Static_assert(__builtin_offsetof(struct boot_args, Video) == 40, "boot_args layout");
_Static_assert(__builtin_offsetof(struct boot_args, CommandLine) == 108, "boot_args layout");
_Static_assert(sizeof(struct boot_args) == 736, "boot_args layout");

static void copy64(u64 dst, u64 src, u64 n)
{
	volatile u64 *d = (volatile u64 *)dst;
	volatile const u64 *s = (volatile const u64 *)src;

	for (u64 i = 0; i < (n + 7) / 8; i++)
		d[i] = s[i];
}

static void zero64(u64 dst, u64 n)
{
	volatile u64 *d = (volatile u64 *)dst;

	for (u64 i = 0; i < n / 8; i++)
		d[i] = 0;
}

static int in_kram(u64 a, u64 len)
{
	return a >= KRAM_LO && a + len >= a && a + len <= KRAM_HI;
}

typedef void (*xnu_entry_t)(u64 boot_args_pa);

void shim_main(u64 dtb)
{
	struct con c = { { OLD_FB, OLD_PITCH }, CON_TOP };
	const struct payload *p = (const struct payload *)((u64)_start + PAYLOAD_FROM_START);
	static const char want[8] = { 'S', 'W', 'E', 'E', 'T', 'X', 'N', 'U' };
	u64 off, adt_pa, ba_pa, top, entry_pa;
	long r = -1;
	u64 kick_cpu = 0;

	wr32(TOPRGU + 0x00, 0x22000000u); /* watchdog off */

	rect(&c.s, 0, CON_TOP - 20, PANEL_W, 40 * CELL_H, COL_BG);
	con_line(&c, "AGATE XNU SHIM " SHIM_VERSION, COL_OK);
	say(&c, "DTB ", dtb, 8);
	kick();

	for (int i = 0; i < 8; i++)
		if (p->magic[i] != want[i])
			fail(&c, "NO SWEETXNU PAYLOAD AT IMAGE+20000");
	if (p->version != 1 || (p->adt_off & 7))
		fail(&c, "BAD PAYLOAD HEADER");
	off = p->phys_base - p->virt_base; /* pa = va + off */
	say(&c, "PHYS ", p->phys_base, 9);
	say(&c, "SIZE ", p->mem_size, 9);
	say(&c, "ENTRY ", p->entry_va + off, 9);
	say(&c, "SEGS ", p->nsegs, 2);
	if (!in_kram(p->phys_base, p->mem_size))
		fail(&c, "KERNEL RAM OUTSIDE 140000000-1C0000000");
	for (u32 i = 0; i < p->nsegs; i++)
		if (!in_kram(p->segs[i].vmaddr + off, p->segs[i].vmsize))
			fail(&c, "SEGMENT OUTSIDE KERNEL RAM");
	kick();

	/* Move the visible layer to ruby's layout (both inside the mblock). */
	rect(&(struct surf){ NEW_FB, NEW_PITCH }, 0, 0, PANEL_W, PANEL_H, COL_BG);
	say(&c, "OVL L1 ADDR WAS ", rd32(OVL_L1_ADDR), 8);
	say(&c, "OVL L1 PITCH WAS ", rd32(OVL_L1_PITCH), 8);
	wr32(OVL_L1_ADDR, (u32)NEW_FB);
	wr32(OVL_L1_PITCH, (rd32(OVL_L1_PITCH) & ~0xffffu) | NEW_PITCH);
	c.s.base = NEW_FB;
	c.s.pitch = NEW_PITCH;
	c.y = CON_TOP;
	con_line(&c, "AGATE XNU SHIM " SHIM_VERSION " - BUFFER 7CDFC000", COL_OK);
	say(&c, "OVL L1 ADDR NOW ", rd32(OVL_L1_ADDR), 8);
	kick();

	/* Frame kicker on an A78 core (MPIDR 0x700 first). */
	for (u64 cpu = 0x700; cpu >= 0x400; cpu -= 0x100) {
		r = psci_cpu_on(cpu, (u64)kicker_entry, 0);
		if (r == 0) {
			kick_cpu = cpu;
			break;
		}
	}
	if (r != 0) {
		say(&c, "PSCI CPU_ON FAILED ", (u64)r, 8);
		fail(&c, "NO FRAME KICKER - SCREEN WOULD FREEZE");
	}
	delay_ms(100); /* from here on only the kicker triggers frames */
	say(&c, "KICKER ON CPU ", kick_cpu, 3);

	for (u32 i = 0; i < p->nsegs; i++) {
		const struct payload_seg *s = &p->segs[i];
		u64 dst = s->vmaddr + off;

		copy64(dst, (u64)p + s->file_off, s->file_size);
		if (s->vmsize > s->file_size)
			zero64(dst + ((s->file_size + 7) & ~7UL),
			    s->vmsize - ((s->file_size + 7) & ~7UL));
	}
	say(&c, "KERNEL END ", p->kernel_end + off, 9);

	adt_pa = p->kernel_end + off;
	ba_pa = (adt_pa + p->adt_size + PAGE_16K - 1) & ~(PAGE_16K - 1);
	top = ba_pa + PAGE_16K;
	if (!in_kram(adt_pa, top - adt_pa))
		fail(&c, "ADT OUTSIDE KERNEL RAM");
	copy64(adt_pa, (u64)p + p->adt_off, p->adt_size);

	zero64(ba_pa, PAGE_16K);
	volatile struct boot_args *ba = (volatile struct boot_args *)ba_pa;
	ba->Revision = 2;
	ba->Version = 2;
	ba->virtBase = p->virt_base;
	ba->physBase = p->phys_base;
	ba->memSize = p->mem_size;
	ba->topOfKernelData = top;
	ba->Video.v_baseAddr = NEW_FB;
	ba->Video.v_display = 1;
	ba->Video.v_rowBytes = NEW_PITCH;
	ba->Video.v_width = PANEL_W;
	ba->Video.v_height = PANEL_H;
	ba->Video.v_depth = 32;
	ba->deviceTreeP = adt_pa - off; /* XNU reads it with the MMU on: a VA */
	ba->deviceTreeLength = (u32)p->adt_size;
	for (int i = 0; i < BOOT_LINE_LENGTH; i++)
		ba->CommandLine[i] = p->cmdline[i];
	ba->memSizeActual = p->mem_size;
	say(&c, "BOOT ARGS ", ba_pa, 9);

	entry_pa = p->entry_va + off;
	say(&c, "JUMP TO XNU ", entry_pa, 9);
	delay_ms(300);

	__asm__ volatile("dsb sy; ic iallu; dsb sy; isb" ::: "memory");
	((xnu_entry_t)entry_pa)(ba_pa);
	fail(&c, "XNU RETURNED");
}
