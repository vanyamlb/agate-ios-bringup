# Wi-Fi on the Xiaomi 11T (MT6893) under XNU: where it stands, what comes next

## Done

**A1 (2026-11-19, patch 0499, `agatewifi=2`).** MediaTek's own MT6893 conninfra power
sequence (`conninfra/platform/mt6893/mt6893_pos.c`,
`consys_conninfra_on_power_ctrl_mt6893`, POS branch without the SPM API) run from XNU:

| | before | after |
|---|---|---|
| `SPM_PWR_STATUS` / `_2ND` (bit 1) | 0 / 0 | 1 / 1 |
| `SPM_CONN_PWR_CON` | `0x12` (iso, clk_dis) | `0x0d` |
| `INFRA_AP2MD_GALS_CTL` | 0 | 1 |
| AXI protect (TX bit 13, RX bit 14, RX2 bit 2) | on | TX/RX2 off |

then `CONN_INFRA_WAKEPU_TOP` = 1, `slpprot` ready, **`CONN_HW_VER` (0x18001000) =
`0x20010101`, `CFG_ID` = 3** - the same id Android's driver reads. Nothing hung; USB networking
kept running.

**A2a + A2b (2026-11-19, patches 0501, `agatewifi=4`).** MediaTek's own `mt6893_pos.c`
(staged at build time by `0501-stage-conninfra.sh`, built in XNU against `bsd/dev/agate_conninfra/compat/`)
runs the whole first power-on of `consys_hw_pwr_on()`; the PMIC is reached over the MT6885-family
pwrap **ARB_V3 / SWINF_2** (`ACC 0xc80`, `WDATA 0xc84`, `RDATA 0xc94`, `VLD_CLR 0xca4`,
`STA 0xca8`; the older WACS2 at `0xc20` does not answer):

```
PMIC VCN18 CON0=0x0001 after enable
PMIC VCN13 ANA_CON0=0x0d00 (1.3 V), CON0=0x0001 after enable
A-die CHIP_ID=0x66358a11            (MT6635 E3)
efuse = [0xa0000000, 0x00b700c4, 0x0000b4f8, 0x79797372]
afe_wbg_cal / subsys_pll_initial / low_power_setting -> 0
WFSYS: rgu_off_hreset released, WF/WFDMA sleep protect off
WFSYS_VERSION_ID=20010000 -> MT6893 Wi-Fi sub-system is ALIVE
```

Two traps on the way: `memset_io` on the conn sysram must be 32-bit device stores (a plain
`memset` faulted with an alignment abort, ESR `0x96000061`), and without VCN18/VCN13 the A-die
reads `0x00000000` while every step still returns 0.

**A3a (2026-11-19, shim AGFW + patch 0502, `agatewifi=5`).** The WM (Wi-Fi) MCU runs its ROM
under XNU. `tools/mkfwblob.py` packs the phone's own ROM EMI images into an "AGFW" blob that
`pack_xnu.py --fw-blob` puts at Image+0x1800000; the shim copies them (32-bit stores, MMU off)
to the conn EMI at `0x8fb00000` + `(addr & 0xFFFFFF)` without their 48-byte header, dates to
`0x27f0e0`/`0x27f0f0`, as gen4m `wlanDownloadEMISection` does. Then, after A2b:

```
EMI+230000 (wmmcu):    30021f46 828b1058 009201dd 08462384   (= soc3_0_ram_wmmcu body)
EMI+2b0000 (wifi-rom): b0020f46 0c000058 009200dd 004600fc   (= soc3_0_ram_wifi body)
A3a: remap=89040000, releasing WM CPU (rgu+0x10=00000000)
A3a: ROM state 00001d1e after 40 ms -> WM MCU ROM is UP, ready for the patch
```

`CONN_CFG_AP2WF_REMAP_1` = `0x89040000`, WF dynamic base `+0x1dc/+0x1e0` = 0, WFSYS semaphore
reset (`0x18000018[0]` = 0), WM CPU out of reset (`0x18000010[0]` = 1), ROM ready code `0x1D1E`
at `0x184c1604`. Next (A3b): WFDMA rings, ROM patch (`soc3_0_patch_wmmcu`) and N9 RAM code
(`WIFI_RAM_CODE_soc3_0_1a_1.bin`, kept in the blob as kind-2 entries) over the connac2 MCU protocol.

## Material collected (not in the repository: the owner's own phone data)

`agate-data/wifi-fw/` on the build machine, read from the running Android with root:

| file | bytes | role |
|---|---|---|
| `soc3_0_ram_mcu_1a_1_hdr.bin` | 165 376 | conn MCU RAM code |
| `soc3_0_ram_wmmcu_1a_1_hdr.bin`, `soc3_0_patch_wmmcu_1a_1_hdr.bin` | 49 868, 5 726 | WM (Wi-Fi MCU) RAM code and ROM patch |
| `soc3_0_ram_wifi_1a_1_hdr.bin`, `WIFI_RAM_CODE_soc3_0_1a_1.bin` | 296 916, 960 552 | Wi-Fi firmware |
| `soc3_0_ram_bt_1a_1_hdr.bin`, `BT_FW.cfg` | | Bluetooth |
| `conninfra.cfg`, `wifi.cfg` | | vendor configuration |
| `nvram-WIFI.bin`, `nvram-WIFI_CUSTOM.bin` | 6146, 6 | per-device calibration (`/mnt/vendor/nvdata/APCFG/APRDEB/`) |
| `android-dmesg.txt`, `android-iomem.txt` | | Android's own bring-up, step by step, and its memory map |

Android reserves the conn EMI region at **`0x8fb00000` + `0x450000`** (dynamic
`consys-reserve-memory`); it is a hole in Android's System RAM, outside XNU's
`0x140000000..0x1c0000000`, and no firmware region overlaps it.

## The rest of the conninfra power-on (A2a)

`consys_hw_pwr_on()` (conninfra/platform/consys_hw.c), first power-on:

1. PMIC common power (`pmic_mng_common_power_ctrl(1)`: VCN13 / VCN18 on the MT6359P,
   `mt6893_pmic.c`) and the clock buffer (`consys_plt_clock_buffer_ctrl`, the conn XO).
   Needs a pwrap writer (ruby's `rubypwrap` code drives the same PMIC family).
2. pinmux (`consys_set_if_pinmux_mt6893`, GPIO 172..182), MTCMOS - **done** - chip id - **done**.
3. EMI remap (`consys_emi_set_remapping_reg_mt6893`, `CONN_HOST_CSR_TOP + 0x1c4`),
   `d_die_cfg`, `spi_master_cfg`, `a_die_cfg` (A-die over the conn SPI master, its efuse),
   `afe_wbg_cal`, `subsys_pll_initial` (BPLL/WPLL: the WF bus clock), status in sysram,
   `low_power_setting`.

Plan: compile `mt6893_pos.c` almost verbatim into XNU behind a small compat header
(`CONSYS_REG_*` on `ml_io_map`ped bases, `udelay`/`mdelay`, `pr_*` to `printf`), one
boot-arg step per part, comparing every register against `android-dmesg.txt`.

## WFSYS on (A2b)

gen4m `chips/soc3_0/soc3_0.c` `wf_pwr_on_consys_mcu()`: wake conninfra
(`0x180601a4`), WM CPU reset (`0x18000010[0]`), bus clocks (BPLL/WPLL in
`CONN_AFE_CTL + RG_DIG_EN_03`), `wfsys_top_on` (`0x18000000` = `0x5746xx80`), poll
`0x180602cc[2]`, WF and WFDMA sleep protect off (`0x18001620/0x18001624`),
`WF_VDNR_EN` (`0x1800e06c[0]`), then **`WFSYS_VERSION_ID` at `0x184b0010` must read
`0x20010000`**; then the ROM patch into EMI and `CONN_CFG_AP2WF_REMAP_1` (`0x18001120`) =
`0x89040000`.

## Firmware and the MAC (A3, A4)

The Wi-Fi block is CONNAC2 (same generation as MT7921/MT7961): firmware download is the
connac2 MCU protocol over WFDMA rings (patch semaphore, target address/length, FW start),
which mainline `mt76` implements for MT7921. Options for the MAC: mt76's connac2 code on
the AXI bus (as `mt7915/soc.c` does for MT7986), or MediaTek's gen4m (`connac2x/6893`).
On the iOS side `oosexgang/hakios-xnu-kernel`'s `hakios.apple80211.c` is the surface
`wifid` expects, radio-agnostic.

## References

- MediaTek sources in the device kernel: `xiaomi-mt6893-dev/kernel_xiaomi_mt6893`
  (lineage-23.2) `drivers/misc/mediatek/connectivity/conninfra/` and `wlan/core/gen4m/`.
- HakiOS X6739 (MT6893): `Xia-s-Projekt/hakios-x6739` `docs/wifi-mt6893.md` - register map
  and plan.
- OnePlus Nord 2 (MT6893) on postmarketOS, gen4m Wi-Fi working on a mainline kernel:
  `bluelightsaber/oneplusnord2-5g-pmos`.
