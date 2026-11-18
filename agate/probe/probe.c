/*
 * agate (Xiaomi 11T, MT6893) display probe, stage 1.
 *
 * Runs instead of the Linux kernel from boot_a. It only:
 *   - turns off the TOPRGU watchdog that LK armed,
 *   - reads display registers (DSI0, mutex, OVL, RDMA),
 *   - writes inside the reserved framebuffer (mblock-20-framebuffer,
 *     0x7b020000..0x7d800000 in the live FDT); every pixel write is bounds
 *     checked against that range,
 *   - re-triggers DSI0 frames if the panel is in command mode,
 *   - reboots after PROBE_SECONDS.
 * It never touches storage, PMIC, GPIO or clocks.
 *
 * Each candidate buffer is labelled with its own address, so a photo of the
 * screen tells which buffer the panel actually scans out.
 */
#include <stdint.h>
#include "font5x7.h"

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;

#define FB_LO 0x7b020000UL
#define FB_HI 0x7d800000UL
#define GUESS_FB 0x7cdfc000UL /* ruby's LK scan buffer; same mblock end */
#define PANEL_W 1080u
#define PANEL_H 2400u

#define TOPRGU 0x10007000UL
#define DSI0 0x1400e000UL
#define MUTEX 0x14117000UL

#define PROBE_SECONDS 60u
#define PROBE_VERSION "1"

#define COL_FILL 0xff203080u
#define COL_FG 0xffffffffu
#define COL_BG 0xff000000u
#define COL_MARK 0xff00ff00u

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

/* ---- framebuffer ---- */

struct surf {
	u64 base;
	u32 pitch;
};

static int in_fb(u64 a, u64 len)
{
	return a >= FB_LO && a + len >= a && a + len <= FB_HI;
}

static void px(const struct surf *s, u32 x, u32 y, u32 c)
{
	u64 a;

	if (x >= PANEL_W || y >= PANEL_H)
		return;
	a = s->base + (u64)y * s->pitch + (u64)x * 4;
	if (!in_fb(a, 4))
		return;
	wr32(a, c);
}

static void rect(const struct surf *s, u32 x, u32 y, u32 w, u32 h, u32 c)
{
	for (u32 j = 0; j < h; j++)
		for (u32 i = 0; i < w; i++)
			px(s, x + i, y + j, c);
}

static void fill_fb(u32 c)
{
	u64 v = ((u64)c << 32) | c;

	for (u64 a = FB_LO; a < FB_HI; a += 8)
		*(volatile u64 *)a = v;
	__asm__ volatile("dsb sy" ::: "memory");
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

static void draw_char(const struct surf *s, u32 x, u32 y, char ch)
{
	const unsigned char *g = font_rows[glyph(ch)];

	for (u32 r = 0; r < 9; r++) {
		for (u32 c = 0; c < 6; c++) {
			int on = r < 7 && c < 5 && ((g[r] >> (4 - c)) & 1);
			rect(s, x + c * SCALE, y + r * SCALE, SCALE, SCALE,
			    on ? COL_FG : COL_BG);
		}
	}
}

static void draw_str(const struct surf *s, u32 x, u32 y, const char *p)
{
	for (; *p; p++, x += CELL_W)
		draw_char(s, x, y, *p);
}

/* ---- text report ---- */

#define MAXL 40
#define LLEN 60

struct text {
	char l[MAXL][LLEN];
	int n;
};

static char *line(struct text *t)
{
	char *p;

	if (t->n >= MAXL)
		return 0;
	p = t->l[t->n++];
	p[0] = 0;
	return p;
}

static void cat(char *p, const char *s)
{
	int n = 0;

	if (!p)
		return;
	while (p[n])
		n++;
	while (*s && n < LLEN - 1)
		p[n++] = *s++;
	p[n] = 0;
}

static void cathex(char *p, u64 v, int digits)
{
	char b[17];

	if (!p)
		return;
	for (int i = digits - 1; i >= 0; i--) {
		u32 d = v & 0xf;
		b[i] = (char)(d < 10 ? '0' + d : 'A' + d - 10);
		v >>= 4;
	}
	b[digits] = 0;
	cat(p, b);
}

static void catkv(char *p, const char *k, u64 v, int digits)
{
	cat(p, k);
	cathex(p, v, digits);
}

/* ---- candidates ---- */

#define MAXC 12

struct cands {
	struct surf s[MAXC];
	int n;
};

static void add_cand(struct cands *c, u64 base, u32 pitch)
{
	if (!in_fb(base, 4) || pitch < PANEL_W * 4 || pitch > 0x2000)
		return;
	for (int i = 0; i < c->n; i++)
		if (c->s[i].base == base && c->s[i].pitch == pitch)
			return;
	if (c->n < MAXC) {
		c->s[c->n].base = base;
		c->s[c->n].pitch = pitch;
		c->n++;
	}
}

/* ---- register reads ---- */

static u32 cur_el(void)
{
	u64 v;
	__asm__ volatile("mrs %0, CurrentEL" : "=r"(v));
	return (u32)((v >> 2) & 3);
}

static void read_cpu(struct text *t, u64 dtb)
{
	u64 midr, mpidr, sctlr;
	u32 el = cur_el();
	char *p;

	__asm__ volatile("mrs %0, midr_el1" : "=r"(midr));
	__asm__ volatile("mrs %0, mpidr_el1" : "=r"(mpidr));
	if (el == 2)
		__asm__ volatile("mrs %0, sctlr_el2" : "=r"(sctlr));
	else
		__asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));

	p = line(t);
	catkv(p, "EL=", el, 1);
	catkv(p, " MIDR=", midr, 8);
	catkv(p, " MPIDR=", mpidr, 8);
	p = line(t);
	catkv(p, "SCTLR=", sctlr, 8);
	catkv(p, " DTB=", dtb, 8);
	catkv(p, " FRQ=", cntfrq(), 8);
}

struct dsi_state {
	u32 mode;
	u32 mutex_mask; /* mutexes that drive a path */
};

static void read_dsi(struct text *t, struct dsi_state *d)
{
	char *p = line(t);

	d->mode = rd32(DSI0 + 0x14);
	catkv(p, "DSI0 MODE=", d->mode, 8);
	catkv(p, " STA=", rd32(DSI0 + 0x04), 8);
	catkv(p, " INT=", rd32(DSI0 + 0x0c), 8);
	p = line(t);
	catkv(p, "DSI0 START=", rd32(DSI0 + 0x00), 8);
	cat(p, (d->mode & 3) == 0 ? " CMD MODE" : " VIDEO MODE");
}

static void read_mutex(struct text *t, struct dsi_state *d)
{
	d->mutex_mask = 0;
	for (u32 n = 0; n < 16; n++) {
		u32 en = rd32(MUTEX + 0x20 + 0x20 * n);
		u32 sof = rd32(MUTEX + 0x2c + 0x20 * n);
		u32 mod = rd32(MUTEX + 0x30 + 0x20 * n);
		u32 mod2 = rd32(MUTEX + 0x34 + 0x20 * n);
		char *p;

		if (!en && !mod && !mod2)
			continue;
		if (mod || mod2)
			d->mutex_mask |= 1u << n;
		p = line(t);
		catkv(p, "MUTEX", n, 1);
		catkv(p, " EN=", en, 1);
		catkv(p, " SOF=", sof, 8);
		catkv(p, " MOD=", mod, 8);
		catkv(p, " ", mod2, 8);
	}
}

static void read_ovl(struct text *t, struct cands *c, u64 base)
{
	u32 en = rd32(base + 0x0c);
	u32 src = rd32(base + 0x2c);
	char *p = line(t);

	catkv(p, "OVL ", base, 8);
	catkv(p, " EN=", en, 8);
	catkv(p, " SRC=", src, 8);
	for (u32 n = 0; n < 4; n++) {
		u32 con, size, pitch, addr;

		if (!(src & (1u << n)))
			continue;
		con = rd32(base + 0x30 + 0x20 * n);
		size = rd32(base + 0x38 + 0x20 * n);
		pitch = rd32(base + 0x44 + 0x20 * n) & 0xffff;
		addr = rd32(base + 0xf40 + 0x20 * n);
		p = line(t);
		catkv(p, " L", n, 1);
		catkv(p, " A=", addr, 8);
		catkv(p, " P=", pitch, 4);
		catkv(p, " S=", size, 8);
		catkv(p, " C=", con, 8);
		add_cand(c, addr, pitch);
	}
}

static void read_rdma(struct text *t, struct cands *c, u64 base)
{
	u32 g = rd32(base + 0x10);
	u32 s0 = rd32(base + 0x14);
	u32 s1 = rd32(base + 0x18);
	u32 pitch = rd32(base + 0x2c);
	u32 addr = rd32(base + 0xf00);
	char *p = line(t);

	catkv(p, "RDMA ", base, 8);
	catkv(p, " G=", g, 8);
	catkv(p, " A=", addr, 8);
	p = line(t);
	catkv(p, " P=", pitch, 8);
	catkv(p, " S0=", s0, 8);
	catkv(p, " S1=", s1, 8);
	if ((g & 1) && (g & 2))
		add_cand(c, addr, pitch);
}

/* ---- output ---- */

static void render(const struct text *t, const struct cands *c, int phase)
{
	for (int i = 0; i < c->n; i++) {
		const struct surf *s = &c->s[i];
		char head[LLEN];
		u32 y = 150;

		head[0] = 0;
		cat(head, "AGATE PROBE " PROBE_VERSION);
		catkv(head, " PH=", (u64)phase, 1);
		catkv(head, " SURF=", s->base, 8);
		catkv(head, " P=", s->pitch, 4);
		rect(s, 0, y - 20, PANEL_W, (u32)(t->n + 2) * CELL_H + 40, COL_BG);
		draw_str(s, 24, y, head);
		y += CELL_H * 2;
		for (int j = 0; j < t->n; j++, y += CELL_H)
			draw_str(s, 24, y, t->l[j]);
		/* corner marks: show the panel's real orientation and edges */
		rect(s, 0, 0, 60, 60, COL_MARK);
		rect(s, PANEL_W - 60, PANEL_H - 60, 60, 60, COL_MARK);
	}
	__asm__ volatile("dsb sy" ::: "memory");
}

static void trigger_frames(const struct dsi_state *d, u32 ms)
{
	u64 end = cntpct() + cntfrq() / 1000 * ms;

	if ((d->mode & 3) != 0) { /* video mode scans continuously */
		delay_ms(ms);
		return;
	}
	while (cntpct() < end) {
		for (u32 w = 0; w < 50 && (rd32(DSI0 + 0x0c) & 0x80000000u); w++)
			delay_ms(1);
		for (u32 n = 0; n < 16; n++)
			if (d->mutex_mask & (1u << n))
				wr32(MUTEX + 0x20 + 0x20 * n, 1);
		wr32(DSI0 + 0x00, 0);
		wr32(DSI0 + 0x00, 1);
		delay_ms(100);
	}
}

void probe_main(u64 dtb)
{
	struct text t;
	struct cands c;
	struct dsi_state d;

	/* LK arms TOPRGU; mode = key 0x22 with the enable bit clear. */
	wr32(TOPRGU + 0x00, 0x22000000u);

	t.n = 0;
	c.n = 0;
	d.mode = 0;
	d.mutex_mask = 0;

	/* Phase 0: whole reserved framebuffer to one colour. */
	fill_fb(COL_FILL);

	read_cpu(&t, dtb);
	read_dsi(&t, &d);
	read_mutex(&t, &d);

	/* Phase 1: pipe 0 (the path LK is most likely to use). */
	read_ovl(&t, &c, 0x14000000UL); /* ovl0 */
	read_ovl(&t, &c, 0x14001000UL); /* ovl0_2l */
	read_ovl(&t, &c, 0x14002000UL); /* ovl2_2l */
	read_rdma(&t, &c, 0x14003000UL); /* rdma0 */
	if (c.n == 0) /* no layer found in the framebuffer: try ruby's layout */
		add_cand(&c, GUESS_FB, 4352);
	render(&t, &c, 1);
	trigger_frames(&d, 8000);

	/* Phase 2: pipe 1 (may be clock-gated; a hang here keeps phase 1). */
	read_ovl(&t, &c, 0x14100000UL); /* ovl1 */
	read_ovl(&t, &c, 0x14101000UL); /* ovl1_2l */
	read_ovl(&t, &c, 0x14102000UL); /* ovl3_2l */
	read_rdma(&t, &c, 0x14103000UL); /* rdma1 */
	render(&t, &c, 2);
	trigger_frames(&d, (PROBE_SECONDS - 8) * 1000);

	/* Software reset: the phone reboots by itself (proof the probe ran). */
	wr32(TOPRGU + 0x14, 0x1209u);
	for (;;)
		__asm__ volatile("wfi");
}
