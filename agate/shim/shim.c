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

/* hidden: PC-relative (adrp/add), never through a GOT */
extern char _start[] __attribute__((visibility("hidden")));
extern char kicker_entry[] __attribute__((visibility("hidden")));

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

/* ---- touch probe (payload cmdline contains "agateshimtouch=1") ----
 *
 * Same bring-up as kernel patch 0093, bare metal: SPI mode 0 bit-banged on
 * the SPI6 pins in GPIO mode (CLK 0, CS 1, MISO 2, MOSI 3), DVDD GPIO27,
 * reset GPIO20; reads the ST FTS (FTM5 SALIXP, id 36 40). Results stay on the
 * screen (the kicker refreshes it), then the boot continues. Only the touch
 * pins are written. */
#define TG_PA 0x10005000UL
#define TG_DIR(p) (TG_PA + 0x000u + ((p) / 32u) * 0x10u)
#define TG_DO(p) (TG_PA + 0x100u + ((p) / 32u) * 0x10u)
#define TG_DI(p) (TG_PA + 0x200u + ((p) / 32u) * 0x10u)
#define TG_MODE(p) (TG_PA + 0x300u + ((p) / 8u) * 0x10u)

static void delay_us(u32 us)
{
	u64 end = cntpct() + cntfrq() / 1000000 * us + 1;
	while (cntpct() < end)
		;
}

static void tg_out(u32 p, int v) { wr32(TG_DO(p) + (v ? 4u : 8u), 1u << (p % 32u)); }
static void tg_dir(u32 p, int o) { wr32(TG_DIR(p) + (o ? 4u : 8u), 1u << (p % 32u)); }
static int tg_in(u32 p) { return (rd32(TG_DI(p)) >> (p % 32u)) & 1; }
static void tg_gpio(u32 p)
{
	u32 sh = (p % 8u) * 4u;
	wr32(TG_MODE(p), rd32(TG_MODE(p)) & ~(0xfu << sh));
}

static u32 tg_pins(int which)
{
	static const u32 pins[7] = { 0, 1, 2, 3, 20, 21, 27 };
	u32 w = 0;
	for (u32 i = 0; i < 7; i++) {
		u32 p = pins[i], v;
		if (which == 0)
			v = (rd32(TG_MODE(p)) >> ((p % 8u) * 4u)) & 0xfu;
		else if (which == 1)
			v = ((rd32(TG_DIR(p)) >> (p % 32u)) & 1u) | (((rd32(TG_DO(p)) >> (p % 32u)) & 1u) << 1);
		else
			v = (u32)tg_in(p);
		w |= v << (i * 4u);
	}
	return w;
}

static void tg_spi(const u8 *tx, u32 ntx, u8 *rx, u32 nrx)
{
	tg_out(1, 0);
	delay_us(2);
	for (u32 i = 0; i < ntx + nrx; i++) {
		u8 out = i < ntx ? tx[i] : 0, in = 0;
		for (int b = 7; b >= 0; b--) {
			tg_out(3, (out >> b) & 1);
			delay_us(1);
			tg_out(0, 1);
			in = (u8)((in << 1) | tg_in(2));
			delay_us(1);
			tg_out(0, 0);
		}
		if (i >= ntx)
			rx[i - ntx] = in;
	}
	tg_out(3, 0);
	delay_us(2);
	tg_out(1, 1);
	delay_us(20);
}

static void tg_read(u8 cmd, int has_addr, u32 addr, u8 *buf, u32 len)
{
	u8 tx[5] = { cmd, (u8)(addr >> 24), (u8)(addr >> 16), (u8)(addr >> 8), (u8)addr };
	u8 rx[9];
	tg_spi(tx, has_addr ? 5 : 1, rx, len + 1);
	for (u32 i = 0; i < len; i++)
		buf[i] = rx[i + 1];
}

static void tg_regw(u32 addr, u8 v)
{
	u8 tx[6] = { 0xFA, (u8)(addr >> 24), (u8)(addr >> 16), (u8)(addr >> 8), (u8)addr, v };
	tg_spi(tx, 6, 0, 0);
}

static void say_hex(struct con *c, const char *k, const u8 *b, u32 n)
{
	char l[LLEN];
	l[0] = 0;
	cat(l, k);
	for (u32 i = 0; i < n; i++) {
		cat(l, " ");
		cathex(l, b[i], 2);
	}
	con_line(c, l, COL_FG);
}

static int cmdline_has(const char *cl, const char *w)
{
	for (u32 i = 0; cl[i] && i < 600; i++) {
		u32 j = 0;
		while (w[j] && cl[i + j] == w[j])
			j++;
		if (!w[j])
			return 1;
	}
	return 0;
}

/* ---- MT6360 LDO block (I2C5, slave 0x64, CRC8) by GPIO bit-bang ----
 * SCL5 = GPIO202, SDA5 = GPIO203 (FUNC 1). Open drain: low = DIR out with
 * DO 0, high = DIR in (board pull-ups). LDO5 (VMCH, touch AVDD): EN_CTRL2
 * 0x0B (bit 6 enable, bit 2 status), CTRL3 0x0F VOUT (0x50 = 3.3 V). */
#define IC_SCL 202u
#define IC_SDA 203u

static void ic_lo(u32 p) { tg_out(p, 0); tg_dir(p, 1); }
static void ic_hi(u32 p) { tg_dir(p, 0); }
static void ic_dly(void) { delay_us(5); }

static void ic_start(void)
{
	ic_hi(IC_SDA); ic_hi(IC_SCL); ic_dly();
	ic_lo(IC_SDA); ic_dly();
	ic_lo(IC_SCL); ic_dly();
}

static void ic_stop(void)
{
	ic_lo(IC_SDA); ic_dly();
	ic_hi(IC_SCL); ic_dly();
	ic_hi(IC_SDA); ic_dly();
}

static int ic_wr(u8 b)
{
	for (int i = 7; i >= 0; i--) {
		if ((b >> i) & 1) ic_hi(IC_SDA); else ic_lo(IC_SDA);
		ic_dly();
		ic_hi(IC_SCL); ic_dly();
		for (int t = 0; t < 1000 && !tg_in(IC_SCL); t++)
			delay_us(1);
		ic_lo(IC_SCL);
	}
	ic_hi(IC_SDA); ic_dly();
	ic_hi(IC_SCL); ic_dly();
	int ack = !tg_in(IC_SDA);
	ic_lo(IC_SCL); ic_dly();
	return ack;
}

static u8 ic_rd(int ack)
{
	u8 b = 0;
	ic_hi(IC_SDA);
	for (int i = 0; i < 8; i++) {
		ic_dly();
		ic_hi(IC_SCL); ic_dly();
		b = (u8)((b << 1) | tg_in(IC_SDA));
		ic_lo(IC_SCL);
	}
	if (ack) ic_lo(IC_SDA); else ic_hi(IC_SDA);
	ic_dly();
	ic_hi(IC_SCL); ic_dly();
	ic_lo(IC_SCL);
	ic_hi(IC_SDA);
	return b;
}

static u8 crc8_07(const u8 *p, u32 n)
{
	u8 c = 0;
	for (u32 i = 0; i < n; i++) {
		c ^= p[i];
		for (int b = 0; b < 8; b++)
			c = (u8)((c & 0x80) ? (c << 1) ^ 0x07 : c << 1);
	}
	return c;
}

/* returns value 0..255, or 0x100 + step on error (0x1nn no ack, 0x2nn bad crc) */
static u32 pm_read(u8 addr, u8 reg, int crc)
{
	u8 d, k;
	ic_start();
	if (!ic_wr((u8)(addr << 1))) { ic_stop(); return 0x101; }
	if (!ic_wr(reg & 0x3f)) { ic_stop(); return 0x102; }
	ic_start();
	if (!ic_wr((u8)(addr << 1 | 1))) { ic_stop(); return 0x103; }
	if (!crc) {
		d = ic_rd(0);
		ic_stop();
		return d;
	}
	d = ic_rd(1);
	k = ic_rd(0);
	ic_stop();
	u8 buf[3] = { (u8)(addr << 1 | 1), (u8)(reg & 0x3f), d };
	if (crc8_07(buf, 3) != k)
		return 0x200 | k;
	return d;
}

static int pm_write(u8 addr, u8 reg, u8 v)
{
	u8 buf[3] = { (u8)(addr << 1), (u8)(reg & 0x3f), v };
	u8 k = crc8_07(buf, 3);
	int ok = 1;
	ic_start();
	ok &= ic_wr(buf[0]);
	ok &= ic_wr(buf[1]);
	ok &= ic_wr(v);
	ok &= ic_wr(k);
	ok &= ic_wr(0);
	ic_stop();
	return ok;
}

static void say_regs(struct con *c, const char *k, const u32 *v, u32 n)
{
	char l[LLEN];
	l[0] = 0;
	cat(l, k);
	for (u32 i = 0; i < n; i++) {
		cat(l, " ");
		cathex(l, v[i], v[i] > 0xff ? 3 : 2);
	}
	con_line(c, l, COL_FG);
}

/* Read LDO5, turn it on at 3.3 V if it is off. Returns 1 if it was enabled now. */
static int vmch_on(struct con *c)
{
	u32 r[6], id;
	int changed = 0;

	ic_hi(IC_SCL); ic_hi(IC_SDA);
	tg_gpio(IC_SCL); tg_gpio(IC_SDA);
	delay_us(50);
	say(c, "I2C5 IDLE SCL/SDA ", (u32)(tg_in(IC_SCL) << 4 | tg_in(IC_SDA)), 2);
	/* 9 clocks to free a stuck bus */
	for (int i = 0; i < 9 && !tg_in(IC_SDA); i++) {
		ic_lo(IC_SCL); ic_dly(); ic_hi(IC_SCL); ic_dly();
	}
	ic_stop();
	id = pm_read(0x34, 0x00, 0);
	say(c, "MT6360 PMU ID (WANT 5X) ", id, 3);
	for (u32 i = 0; i < 6; i++)
		r[i] = pm_read(0x64, (u8)(0x0A + i), 1);
	say_regs(c, "LDO5 0A-0F", r, 6);
	if (r[1] < 0x100 && r[5] < 0x100 && (!(r[1] & 0x40) || !(r[1] & 0x04))) {
		if ((r[5] & 0x7f) != 0x50)
			pm_write(0x64, 0x0F, (u8)((r[5] & 0x80) | 0x50));
		pm_write(0x64, 0x0B, (u8)(r[1] | 0x40));
		delay_ms(5);
		for (u32 i = 0; i < 6; i++)
			r[i] = pm_read(0x64, (u8)(0x0A + i), 1);
		say_regs(c, "LDO5 AFTER", r, 6);
		changed = 1;
	}
	con_line(c, (r[1] < 0x100 && (r[1] & 0x04)) ? "VMCH (AVDD) ON" : "VMCH STATE UNKNOWN/OFF",
		 (r[1] < 0x100 && (r[1] & 0x04)) ? COL_OK : COL_ERR);
	/* hand the pins back to the I2C controller */
	ic_hi(IC_SCL); ic_hi(IC_SDA);
	{
		u32 sh = (IC_SCL % 8u) * 4u, sh2 = (IC_SDA % 8u) * 4u;
		u32 m = rd32(TG_MODE(IC_SCL));
		m = (m & ~(0xfu << sh) & ~(0xfu << sh2)) | (1u << sh) | (1u << sh2);
		wr32(TG_MODE(IC_SCL), m);
	}
	return changed;
}

static void touch_probe(struct con *c)
{
	u8 e[8], id[4];
	int ready = 0;
	u32 events = 0, touches = 0;

	con_line(c, "TOUCH PROBE: ST FTS ON SPI6 (GPIO BIT-BANG)", COL_OK);
	vmch_on(c);
	kick();
	say(c, "PINS BEFORE MODE ", tg_pins(0), 7);
	say(c, "  DIR/OUT ", tg_pins(1), 7);
	say(c, "  IN ", tg_pins(2), 7);
	tg_out(0, 0); tg_out(1, 1); tg_out(3, 0);
	tg_dir(0, 1); tg_dir(1, 1); tg_dir(3, 1); tg_dir(2, 0); tg_dir(21, 0);
	for (u32 p = 0; p <= 3; p++)
		tg_gpio(p);
	tg_gpio(21);
	tg_out(27, 1); tg_dir(27, 1); tg_gpio(27);
	tg_out(20, 0); tg_dir(20, 1); tg_gpio(20);
	delay_ms(10);
	tg_out(20, 1);
	say(c, "PINS AFTER  MODE ", tg_pins(0), 7);
	say(c, "  DIR/OUT ", tg_pins(1), 7);
	say(c, "  IN ", tg_pins(2), 7);
	kick();

	for (int i = 0; i < 50 && !ready; i++) {
		delay_ms(20);
		tg_read(0x87, 0, 0, e, 8);
		if (i == 0)
			say_hex(c, "FIFO FIRST", e, 8);
		if (e[0] != 0 && e[0] != 0xff && i != 0)
			say_hex(c, "FIFO", e, 8);
		ready = e[0] == 0x03;
	}
	say(c, "CONTROLLER READY ", (u32)ready, 1);
	if (!ready) {
		tg_regw(0x20000032, 0x10);
		tg_regw(0x20000034, 0x02);
		tg_regw(0x2000003E, 0x07);
		tg_regw(0x2000003D, 0x30);
		tg_regw(0x2000002D, 0x02);
		delay_ms(10);
		con_line(c, "SPI4 MODE SET", COL_FG);
	}
	tg_read(0xFB, 1, 0x20000000, id, 2);
	tg_read(0xFB, 1, 0x20000004, id + 2, 2);
	say_hex(c, "CHIP ID / FW (WANT 36 40)", id, 4);
	kick();
	if (id[0] != 0x36 || id[1] != 0x40) {
		con_line(c, "NO ST FTS ANSWER - AVDD/VMCH OFF?", COL_ERR);
		delay_ms(15000);
		return;
	}
	{
		static const u8 scan[3] = { 0xA0, 0x00, 0x01 };
		tg_spi(scan, 3, 0, 0);
	}
	con_line(c, "ACTIVE SCAN ON - TOUCH THE SCREEN NOW (30 S)", COL_OK);
	u32 yline = c->y;
	u64 end = cntpct() + cntfrq() * 30;
	while (cntpct() < end) {
		for (int n = 0; n < 32; n++) {
			tg_read(0x87, 0, 0, e, 8);
			if (e[0] == 0 || e[0] == 0xff)
				break;
			events++;
			if (e[0] == 0x13)
				touches++;
			c->y = yline;
			say(c, "EVENTS ", events, 4);
			say(c, "TOUCHES ", touches, 4);
			say_hex(c, "LAST", e, 8);
			if (e[0] == 0x13 || e[0] == 0x23 || e[0] == 0x33) {
				char l[LLEN];
				l[0] = 0;
				cat(l, "FINGER ");
				cathex(l, e[1] >> 4, 1);
				cat(l, " X ");
				cathex(l, (u32)(e[3] << 8 | e[2]) / 10u, 4);
				cat(l, " Y ");
				cathex(l, (u32)(e[5] << 8 | e[4]) / 10u, 4);
				con_line(c, l, COL_OK);
				c->y -= CELL_H;
			}
			if ((e[7] & 0x1f) == 0)
				break;
		}
		delay_ms(8);
	}
	c->y = yline + 4 * CELL_H;
	con_line(c, "TOUCH PROBE DONE", COL_OK);
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
	if (cmdline_has(p->cmdline, "agateshimtouch=1"))
		touch_probe(&c);
	else if (cmdline_has(p->cmdline, "agatevmch=1"))
		vmch_on(&c);   /* touch AVDD for the kernel FTS driver (0093) */

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
