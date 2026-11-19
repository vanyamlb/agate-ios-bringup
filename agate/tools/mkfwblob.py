#!/usr/bin/env python3
"""Build the agate Wi-Fi firmware blob ("AGFW") that the shim places in the
conninfra EMI region before XNU starts (pack_xnu.py --fw-blob).

  mkfwblob.py FIRMWARE_DIR OUT

FIRMWARE_DIR holds the phone's own /vendor/firmware files (never published).
Entries (all little endian):
  header  "AGFW", u32 version=1, u32 count, u32 total_size
  entry   u32 kind, u32 dest, u32 len, u32 data_off, char name[16]
          kind 1: the shim copies len bytes to EMI base + dest
          kind 2: left in the Image; the kernel writes it to WF MCU address
                  dest through the AP2WF dynamic memory map window, in order
                  (first "patch", then the "ram*" regions)
          kind 3: left in the Image for the kernel as data ("nvram": the
                  phone's nvram-WIFI.bin, sent as CMD_ID_SET_NVRAM_SETTINGS
                  fragments)
As gen4m's soc3_0 download (CFG_DOWNLOAD_DYN_MEMORY_MAP=1, ROM_PATCH_NO_SEM_CTRL):
- the MCU and Wi-Fi "ROM EMI" images go to (u4PatchAddr & 0xFFFFFF) without
  their 48-byte ROM_EMI_HEADER, their 16-byte build dates to
  WMMCU_MCU_ROM_EMI_DATE_ADDR / WMMCU_WIFI_ROM_EMI_DATE_ADDR;
- the ROM patch (PATCH_FORMAT_T, 30-byte header) to SOC3_0_PATCH_START_ADDR
  0x00100000, its date to WMMCU_ROM_PATCH_DATE_ADDR;
- WIFI_RAM_CODE regions from the connac tailer: DOWNLOAD_CONFIG_EMI (bit 7)
  regions into the EMI, plain ones over the dynamic memory map.
"""
import struct
import sys
from pathlib import Path

ROM_EMI_HDR = 48
EMI_MASK = 0xFFFFFF
EMI_SIZE = 0x450000
PATCH_DATE = 0xF027F0D0
PATCH_ADDR = 0x00100000
MCU_DATE = 0xF027F0E0
WIFI_DATE = 0xF027F0F0


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    d = Path(sys.argv[1])
    entries = []   # (kind, dest, data, name)

    def rom_emi(fname, date_addr, tag):
        raw = (d / fname).read_bytes()
        if raw[16:20] != b"ALPS":
            raise SystemExit(f"{fname}: no ALPS ROM EMI header")
        addr = struct.unpack_from("<I", raw, 0x18)[0]
        dest = addr & EMI_MASK
        body = raw[ROM_EMI_HDR:]
        if dest + len(body) > EMI_SIZE:
            raise SystemExit(f"{fname}: {dest:#x}+{len(body):#x} beyond EMI")
        entries.append((1, dest, body, tag))
        entries.append((1, date_addr & EMI_MASK, raw[:16], tag + "-date"))
        print(f"{fname}: {len(body)} B to EMI+{dest:#x}, date {raw[:16]!r}")

    rom_emi("soc3_0_ram_wmmcu_1a_1_hdr.bin", MCU_DATE, "wmmcu")
    rom_emi("soc3_0_ram_wifi_1a_1_hdr.bin", WIFI_DATE, "wifi-rom")
    raw = (d / "soc3_0_patch_wmmcu_1a_1_hdr.bin").read_bytes()
    if raw[16:20] != b"ALPS" or struct.unpack_from("<I", raw, 24)[0] == 0xFFFFFFFF:
        raise SystemExit("patch: not a V1 PATCH_FORMAT_T")
    entries.append((2, PATCH_ADDR, raw[30:], "patch"))
    entries.append((1, PATCH_DATE & EMI_MASK, raw[:16], "patch-date"))
    print(f"patch: {len(raw) - 30} B to WF {PATCH_ADDR:#x}, date {raw[:16]!r}")

    raw = (d / "WIFI_RAM_CODE_soc3_0_1a_1.bin").read_bytes()
    nreg = raw[-36 + 2]
    base = len(raw) - 36 - nreg * 40
    off = 0
    for i in range(nreg):
        _crc, _real, _blk, _r, addr, ln, feat = struct.unpack_from("<III4sIIB", raw, base + i * 40)
        body = raw[off:off + ln]
        off += ln
        if feat & 0x40:                       # FW_FEATURE_NOT_DOWNLOAD
            continue
        if feat & 0x01:                       # encrypted: needs PDA scatter
            raise SystemExit(f"ram region {i}: encrypted, not supported")
        if feat & 0x80:                       # DOWNLOAD_CONFIG_EMI
            dest = addr & EMI_MASK
            if dest + ln > EMI_SIZE:
                raise SystemExit(f"ram region {i}: beyond EMI")
            entries.append((1, dest, body, f"ram{i}-emi"))
            print(f"ram region {i}: {ln:#x} B to EMI+{dest:#x}")
        else:
            entries.append((2, addr, body, f"ram{i}"))
            print(f"ram region {i}: {ln:#x} B to WF {addr:#x} (dyn mem map)")
    if off > base:
        raise SystemExit("ram code: regions overlap the tailer")

    nv = (d / "nvram-WIFI.bin").read_bytes()
    entries.append((3, 0, nv, "nvram"))
    print(f"nvram: {len(nv)} B, MAC {nv[4:10].hex(':')}, country {nv[10:12]!r}")

    head = 16 + 32 * len(entries)
    off = (head + 63) & ~63
    table, data = b"", b""
    for kind, dest, body, name in entries:
        table += struct.pack("<IIII16s", kind, dest, len(body), off, name.encode())
        pad = (-len(body)) & 63
        data += body + b"\0" * pad
        off += len(body) + pad
    blob = b"AGFW" + struct.pack("<III", 1, len(entries), off) + table
    blob += b"\0" * (((head + 63) & ~63) - len(blob)) + data
    assert len(blob) == off
    Path(sys.argv[2]).write_bytes(blob)
    print(f"blob {len(blob)} B, {len(entries)} entries")


if __name__ == "__main__":
    main()
