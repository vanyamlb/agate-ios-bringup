# agate: Xiaomi 11T (MT6893) bring-up

Work in progress: porting this project's XNU/iOS 16 bring-up from `ruby`
(MT6877) to the Xiaomi 11T (`agate`, MediaTek Dimensity 1200 / MT6893).

## Differences from ruby (live FDT)

| Block | agate | ruby |
|---|---|---|
| CPUs | 4× Cortex-A55 (`0xd05`) + 4× Cortex-A78 (`0xd41`), no PAC | 6× A55 + 2× A78 |
| Boot image | v2, page 2048, kernel `0x40080000`, 128 MiB, slots a/b both usable | same, slot b broken |
| `fastboot boot` | not supported by LK (image is accepted, then ignored) | same |
| GIC / timer / PSCI | GICv3 `0x0c000000`/`0x0c040000`, 13 MHz, PSCI 1.0 | same |
| UFS | `0x11270000`, IRQ SPI 105 | IRQ SPI 137 |
| Framebuffer mblock | `0x7b020000` + `0x27e0000` (ends `0x7d800000`) | `0x7ba10000` + `0x1df0000` (same end) |
| Panel | `k11t_42_02_0a_dsc_cmd`: DSI **command mode** + DSC | refreshed without triggers |
| Display blocks | DSI0 `0x1400e000`, mutex `0x14117000`, OVL `0x14000000`/`0x14001000`/`0x14002000`, pipe 1 at `0x141xxxxx` | — |
| Touch | ST FTS on SPI6 `0x1101d000`, IRQ SPI 165 | Goodix on SPI3 |

`atag,videolfb-fb_base_l` (`0x7e020000`) points into TEE/GZ reserved memory
and must not be written. The probe only writes inside the framebuffer mblock.

## Stage 1: display probe (`probe/`)

A ~6 KiB payload that LK runs from `boot_a` instead of Linux. It turns off
the watchdog, paints the framebuffer mblock, reads DSI0/mutex/OVL/RDMA state,
labels every candidate scan-out buffer with its own address, re-triggers
frames if the panel is in command mode, and reboots after 60 s. It never
touches storage, PMIC, GPIO or clocks.

```sh
sh agate/probe/build.sh                       # needs aarch64-linux-gnu-gcc
python3 agate/tools/pack_probe.py --base boot_a.img \
    --payload agate/probe/out/probe.bin --out probe-boot.img
```

The `agate-probe` workflow builds `probe.bin` on GitHub Actions.

Flash only to the slot that does not hold Android, and keep the original
image for that slot:

```sh
fastboot flash boot_a probe-boot.img
fastboot --set-active=a
fastboot reboot
# back to Android: hold Power + Volume down for fastboot, then
fastboot --set-active=b
fastboot reboot
```

### Probe 1 result (2026-11-18)

The panel showed the probe output; phase 2 completed (pipe-1 reads are safe).

| Item | Value |
|---|---|
| Visible buffer | **`0x7ba16000`, pitch 4320**, 1080×2400: OVL0 (`0x14000000`) layer L1, `L1_CON=0x000021ff` |
| Layer below | OVL0_2L (`0x14001000`) L0, `0x7b020000`, pitch 4352 |
| DSI0 | `MODE_CTRL=0` (command mode); frames reach the panel after mutex0 `EN=1` + `DSI_START` 0→1 |
| Mutex 0 | `MOD=0x22000bf7`, `MOD2=0x1`, `SOF=0` |
| CPU at entry | EL1, MIDR `0x412fd050` (A55 r2p0), MPIDR `0x81000000`, MMU off (`SCTLR_EL1=0x30d00800`) |
| DTB / timer | `0x47c80000`, 13 MHz |
| RDMA0, pipe 1 | idle |

For XNU: patches 0010/0012 need `0x7ba16000` / stride 4320; the buffer
crosses the `0x7c000000` 32 MiB boundary, so the early V=P mapping needs two
L2 blocks; the framebuffer flush must re-trigger mutex0 and DSI0 after each
frame (command-mode panel).

## Stage 2: XNU (`shim/`, `tools/`, `ci/`, workflow `agate-xnu`)

| Piece | What it does |
|---|---|
| `ci/prepare-agate.sh` | sweet baseline 0001-0079 (+ `ci/baseline-changes.patch`) + ruby 0080-0083; every later ruby patch drives MT6877 hardware and is dropped |
| `shim/` | iBoot stand-in at Image+0x1000: watchdog off, moves OVL0 L1 to ruby's buffer layout (`0x7cdfc000`, pitch 4352) so the early-console patches apply unchanged, starts a frame kicker on an A78 core (PSCI `CPU_ON`, mutex0 + DSI_START at ~30 Hz, heartbeat square), copies the payload into `0x140000000`+2 GiB and jumps to XNU |
| `tools/mkadt_agate.py` | minimal ADT: 4× A55, GICv3, 13 MHz timer, framebuffer; **no `/sweet-ufs`**, so the kernel cannot reach storage |
| `config/xnu1.cmdline` | `cpus=1`, `rd=md0` (no root yet), all sweet hardware drivers off |
| `tools/pack_xnu.py` | packs shim + payload into the boot image's kernel slot, keeping everything else byte-identical |

Expected first result: shim log, then XNU's early console and stage marks,
ending at the root-device wait (there is no root filesystem yet).

### XNU result 1 (2026-11-18)

First boot of this pipeline (kernel run 44399552896, payload run 44404841296):
the shim log, the frame kicker heartbeat and then XNU's console on the panel.
XNU takes the agate-shim boot_args and ADT, brings up the platform expert,
AMFI/Sandbox stand-ins, AppleKeyStore, IOWatchdog, AppleCLCD
(`1080x2400 stride 4352 at 0x7cdfc000`), CPU 0 with SGI, the VM, BSD, HFS,
mbufs and `lo0`/`gif0`/`stf0`, then stops with the expected
`IOFindBSDRoot: specified root memory device, md0, has not been configured`
(no root filesystem yet). The heartbeat keeps running after the panic.
Returning to Android: fastboot `--set-active=b`.

## Stage 3: first userspace process (`init/`)

`init/agate-init.S` is a tiny PID 1: the mockfs RAM disk *is* this
executable (served as `/sbin/launchd`). It prints a banner with its PID to
`/dev/console` and a tick every 5 s. Build on macOS with the Command Line
Tools only (no Xcode):

```sh
clang -target arm64-apple-ios16.0 -c agate/init/agate-init.S -o agate-init.o
python3 <ios-topaz>/tools/mkinit.py agate-init.o agate-init      # static, ad-hoc signed
python3 <ios-topaz>/tools/mkpayload.py kernel.development.sweet agate.adt payload.bin \
    --ramdisk agate-init --cmdline "$(cat agate/config/xnu1.cmdline)"
python3 agate/tools/pack_xnu.py --base boot_a.img --shim shim.bin --payload payload.bin --out boot.img
```

### PID 1 result (2026-11-19)

`BSD root: md0` -> `load_init_program: attempting to load /sbin/launchd` ->
`*** AGATE: iOS userspace on Xiaomi 11T, init running as PID 1 ***` ->
`AGATE init: alive, tick 01..13` every 5 s, no panic. Mach-O exec, ad-hoc
code signature, syscalls, devfs and the scheduler work on MT6893. Next: a real
iOS 16 root filesystem.

### UFS probe result (2026-11-19)

With `agateufsprobe=1` (0090) XNU took over the UFS host LK left running and
read the GPT of LUN 2: 77 partitions, matching Android (`boot_a` at 4K block
170752, `super` at 419840 / 8704 MiB, `userdata` at 3373056 / 230871 MiB),
then `probe done, 77 partitions, nothing written` and PID 1 as before. The
UFS read path works on MT6893 without any change to the ruby driver.

## Result: iOS 16.7.16 lock screen on the Xiaomi 11T (2026-11-19)

Kernel with 0090-0092, ADT with the iPhone X `/product` node (from the
IPSW's `DeviceTree.d22ap.im4p`), root in the free tail of `super`
(`ufsroot=super ufsoffset=944128 ufsblocks=1280000`, HFS-compressed, LZVN/
LZBITMAP rewritten as zlib by `tools/hfs_zlib.py`), ruby's ICL NOP in
`dyld_shared_cache_arm64.15`, `sweetfb_noconsole=1`: Apple logo, then the
lock screen with the clock (date "31 December": no RTC). 4 A55 cores; no
touch yet (ST FTS on SPI6 needs its own driver). Android, its data and slot b
are untouched; the Android part of `super` hashes the same before and after
each root write.

## Result: iOS home screen on the Xiaomi 11T (2026-11-19)

With ruby's 0084 synthetic swipe kept in the patchset and a later window
(`sweetautoswipe=150000 sweetautoswiperetry=30000 sweetautoswipeattempts=8`,
`config/xnu9-autoswipe-late.cmdline`: on 4 A55 cores the lock screen comes
later than on ruby's 6), the swipe unlocks to the iOS 16.7.16 home screen.
Seen on screen: kernel text, the Xiaomi logo (LK's picture in the lower layer
OVL0_2L L0 at 0x7b020000 shows through iOS's first transparent frame), the
Apple logo, the lock screen, the home screen.

Next: clear the lower layer in the shim; a polled ST FTS touch driver on SPI6.

## Result: touch and 7 cores (2026-11-19)

The ST FTS answered over SPI (id `36 40`, scan command acknowledged) but
reported no touches: its analog supply AVDD = VMCH = **MT6360 LDO5** was off.
The shim now powers it before XNU starts (`agatevmch=1`): bit-banged I2C5
(SCL GPIO202, SDA GPIO203, slave `0x64`, CRC8 poly `0x07`), LDO5 VOUT
(`0x0F`) = `0x50` (3.3 V), EN_CTRL2 (`0x0B`) |= `0x40`; the pins go back to
I2C mode afterwards. With that, kernel patch 0093 (polled FTS on SPI6) drives
SweetHID and touch works on the iOS home screen.

`mkadt_agate.py --big 3` adds the A78 cores at MPIDR `0x400`-`0x600`
(`0x700` runs the shim's frame kicker); every CPU node keeps
`qcom,kryo470` in `compatible` (SweetCPU matches on it, without it the boot
panics with "CPU registration timeout"). `config/xnu12-touch-big.cmdline`:
`cpus=7`, `agatetouch=1`, `agatevmch=1`. The UI is a little faster (still
CPU rendering: there is no GPU driver).

## Result: USB device mode and the kernel log over USB (2026-11-19)

`base=ruby` (workflow input; `AGATE_BASE=ruby`) builds the whole ruby set
(0001-0334, MediaTek MTU3 USB device stack included) plus the agate patches
rebased as `agate/patches-ruby/0490-0495`. The MTU3/IPPC/PHY blocks of
MT6893 sit at the same addresses as on MT6877 (`0x11201000`, `0x11203e00`,
`0x11e40000`). 0495: `rubyps5169=0` skips ruby's PS5169 enable on GPIO121,
an I2C SDA line on agate. `config/xnu15-usb.cmdline` adds `rubyusb=1
rubyps5169=0 rubyusbirq=0` (polled; ruby's IRQ service has MT6877's INTID).

46 s after reset the Mac enumerates `ruby USB P2` (`1209:0002`), iOS boots
as before (7 cores, touch, kernel-driven frames), and
`tools/usblog.py dump|follow OUT` (pyusb + libusb, read-only vendor
requests 0x2B/0x2A) pulls the whole console ring off the phone: no more
filming the screen.
