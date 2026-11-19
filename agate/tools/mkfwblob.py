#!/usr/bin/env python3
"""Build the agate Wi-Fi firmware blob ("AGFW") that the shim places in the
conninfra EMI region before XNU starts (pack_xnu.py --fw-blob).

  mkfwblob.py FIRMWARE_DIR OUT

FIRMWARE_DIR holds the phone's own /vendor/firmware files (never published).
Entries (all little endian):
  header  "AGFW", u32 version=1, u32 count, u32 total_size
  entry   u32 kind, u32 dest, u32 len, u32 data_off, char name[16]
          kind 1: the shim copies len bytes to EMI base + dest
          kind 2: kept in place in the Image for the kernel (dest unused)
As gen4m's soc3_0 power-on download (ENUM_WLAN_POWER_ON_DOWNLOAD_EMI):
the MCU and Wi-Fi "ROM EMI" images go to (u4PatchAddr & 0xFFFFFF) without
their 48-byte ROM_EMI_HEADER, and their 16-byte build dates to
WMMCU_MCU_ROM_EMI_DATE_ADDR / WMMCU_WIFI_ROM_EMI_DATE_ADDR.
"""
import struct
import sys
from pathlib import Path

ROM_EMI_HDR = 48
EMI_MASK = 0xFFFFFF
EMI_SIZE = 0x450000
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
    for fname, tag in (("soc3_0_patch_wmmcu_1a_1_hdr.bin", "patch"),
                       ("WIFI_RAM_CODE_soc3_0_1a_1.bin", "ramcode")):
        raw = (d / fname).read_bytes()
        entries.append((2, 0, raw, tag))
        print(f"{fname}: {len(raw)} B kept for the kernel")

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
