#!/usr/bin/env python3
"""Pull the XNU console log off the phone over ruby's USB EP0 channel.

The kernel (ruby USB stack, boot-arg rubyusb=1) enumerates as 1209:0002
"ruby USB P2". Vendor IN 0xC0/0x2B returns the log descriptor ("SLOG",
version, ring size, u64 total); 0xC0/0x2A with wValue/wIndex = offset
returns up to 64 bytes of the 4 MiB console ring from that offset.
Read-only: no OUT request is sent.

  usblog.py dump OUT.txt          # everything still in the ring
  usblog.py follow OUT.txt        # dump, then keep appending new text

Needs pyusb and libusb (macOS: brew install libusb; DYLD_LIBRARY_PATH may
have to point at /opt/homebrew/lib).
"""
import struct
import sys
import time

import usb.core

VID, PIDS = 0x1209, (0x0002, 0x0003)   # P2 vendor/ACM, agate ECM
SLICE = 64
RING = 4 << 20


def open_dev():
    dev = None
    for pid in PIDS:
        dev = usb.core.find(idVendor=VID, idProduct=pid)
        if dev is not None:
            break
    if dev is None:
        raise SystemExit("ruby USB device 1209:0002/0003 not found")
    return dev


def info(dev):
    raw = bytes(dev.ctrl_transfer(0xC0, 0x2B, 0, 0, 32, timeout=3000))
    magic, ver, size, lo, hi = struct.unpack_from("<5I", raw)
    if magic != 0x474F4C53:
        raise SystemExit("bad log descriptor %r" % raw[:8])
    return size, lo | (hi << 32)


def read_range(dev, start, end, out, quiet=False):
    off = start
    errors = 0
    while off < end:
        try:
            chunk = bytes(dev.ctrl_transfer(0xC0, 0x2A, off & 0xFFFF,
                                            (off >> 16) & 0xFFFF, SLICE,
                                            timeout=3000))
        except usb.core.USBError as e:
            errors += 1
            if errors > 20:
                raise
            # a stall halts EP0 IN for this handle only: reopen
            time.sleep(0.05)
            usb.util.dispose_resources(dev)
            dev = open_dev()
            continue
        if not chunk:
            break
        out.write(chunk)
        off += len(chunk)
        if not quiet and (off - start) % (SLICE * 512) == 0:
            sys.stderr.write("\r%d / %d bytes" % (off - start, end - start))
    out.flush()
    return dev, off


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("dump", "follow"):
        raise SystemExit(__doc__)
    mode, path = sys.argv[1], sys.argv[2]
    dev = open_dev()
    size, total = info(dev)
    start = max(0, total - min(size, RING) + SLICE)
    with open(path, "ab") as out:
        dev, off = read_range(dev, start, total, out)
        sys.stderr.write("\rlog %d bytes (from %d)\n" % (off - start, start))
        while mode == "follow":
            time.sleep(0.5)
            try:
                _, total = info(dev)
            except usb.core.USBError:
                time.sleep(1)
                try:
                    dev = open_dev()
                except SystemExit:
                    continue
                continue
            if total > off:
                dev, off = read_range(dev, off, total, out, quiet=True)


if __name__ == "__main__":
    main()
