#!/usr/bin/env python3
"""Pack the agate shim + SWEETXNU payload into a boot image's kernel slot.

Decompressed Image layout (LK loads it at 0x40080000):
  +0x00000  original ARM64 Image header, code0 = branch to +0x1000
  +0x01000  shim.bin            (must end below +0xb000: kicker stack)
  +0x20000  payload.bin         (tools/mkpayload.py output, "SWEETXNU")
  rest      deterministic pseudo-random filler, then zeros

The old Linux kernel bytes are dropped. As in pack_probe.py the gzip stream
keeps the stock compressed size (FEXTRA padding), so header, ramdisk, DTB and
AVB data stay byte-identical; the XNU payload compresses better than the
Linux kernel it replaces, so incompressible filler (as ruby did) brings the
stream up to within FEXTRA range. The result is verified before writing.
"""
import argparse
import hashlib
import random
import struct
import zlib

SHIM_OFF = 0x1000
SHIM_MAX = 0xa000
PAYLOAD_OFF = 0x20000
TARGET_EXTRA = 30000
FILL_SEED = 0xA6A7E


def build_raw(raw, shim, payload, fill_len):
    mod = bytearray(len(raw))
    mod[0:0x40] = raw[0:0x40]
    mod[0:4] = struct.pack("<I", 0x14000000 | (SHIM_OFF // 4))
    mod[SHIM_OFF:SHIM_OFF + len(shim)] = shim
    end = PAYLOAD_OFF + len(payload)
    mod[PAYLOAD_OFF:end] = payload
    fill_len = max(0, min(fill_len, len(mod) - end))
    mod[end:end + fill_len] = random.Random(FILL_SEED).randbytes(fill_len)
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    return mod, co.compress(bytes(mod)) + co.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", required=True, help="known-good boot image")
    ap.add_argument("--shim", required=True)
    ap.add_argument("--payload", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--expect-base-sha", help="refuse other base images")
    args = ap.parse_args()

    if args.out == args.base:
        raise SystemExit("refusing to overwrite the base image")
    base = open(args.base, "rb").read()
    shim = open(args.shim, "rb").read()
    payload = open(args.payload, "rb").read()
    base_sha = hashlib.sha256(base).hexdigest()
    if args.expect_base_sha and not base_sha.startswith(args.expect_base_sha):
        raise SystemExit(f"base sha256 {base_sha} does not match")
    if base[:8] != b"ANDROID!":
        raise SystemExit("not an Android boot image")
    if len(shim) > SHIM_MAX:
        raise SystemExit(f"shim is {len(shim)} bytes (max {SHIM_MAX:#x})")
    if payload[:8] != b"SWEETXNU":
        raise SystemExit("payload has no SWEETXNU magic")
    kernel_size = struct.unpack_from("<I", base, 8)[0]
    page = struct.unpack_from("<I", base, 36)[0]
    if struct.unpack_from("<I", base, 40)[0] != 2 or page != 2048:
        raise SystemExit("unexpected boot image header")

    raw = zlib.decompress(base[page:page + kernel_size], 16 + zlib.MAX_WBITS)
    if raw[0x38:0x3c] != b"ARMd":
        raise SystemExit("ARM64 Image magic not found")
    end = PAYLOAD_OFF + len(payload)
    if end > len(raw):
        raise SystemExit(f"payload ends at {end:#x}, Image is {len(raw):#x}")

    budget = kernel_size - 20
    fill = 0
    mod, deflate = build_raw(raw, shim, payload, 0)
    if len(deflate) > budget:
        raise SystemExit(f"payload too large: deflate {len(deflate)} > {budget}")
    # Random bytes grow the deflate stream ~1:1; a few secant steps suffice.
    for _ in range(8):
        extra_len = budget - len(deflate)
        if 0 <= extra_len <= 0xFFFF:
            break
        fill = max(0, fill + extra_len - TARGET_EXTRA)
        if fill > len(raw) - end:
            raise SystemExit("not enough room for filler")
        mod, deflate = build_raw(raw, shim, payload, fill)
    else:
        raise SystemExit(f"cannot fit gzip stream: extra={budget - len(deflate)}")

    header = (b"\x1f\x8b\x08\x04" + b"\x00" * 4 + b"\x02\x03"
              + struct.pack("<H", extra_len))
    footer = struct.pack("<II", zlib.crc32(mod) & 0xFFFFFFFF, len(mod) & 0xFFFFFFFF)
    gz = header + b"\x00" * extra_len + deflate + footer
    assert len(gz) == kernel_size

    img = bytearray(base)
    img[page:page + kernel_size] = gz
    assert len(img) == len(base)
    assert img[:page] == base[:page], "header changed"
    assert img[page + kernel_size:] == base[page + kernel_size:], \
        "data outside the kernel slot changed"
    check = zlib.decompress(bytes(gz), 16 + zlib.MAX_WBITS)
    assert check[0x38:0x3c] == b"ARMd"
    assert check[4:0x40] == raw[4:0x40], "Image header changed"
    assert struct.unpack_from("<I", check, 0)[0] == 0x14000000 | (SHIM_OFF // 4)
    assert check[SHIM_OFF:SHIM_OFF + len(shim)] == shim
    assert check[PAYLOAD_OFF:end] == payload

    with open(args.out, "wb") as f:
        f.write(img)
    print(f"base     {base_sha}")
    print(f"shim     {len(shim)} B at Image+{SHIM_OFF:#x}, sha256 {hashlib.sha256(shim).hexdigest()}")
    print(f"payload  {len(payload)} B at Image+{PAYLOAD_OFF:#x}, sha256 {hashlib.sha256(payload).hexdigest()}")
    print(f"kernel   {kernel_size} B gzip, extra={extra_len}, filler={fill:#x}")
    print(f"out      {hashlib.sha256(img).hexdigest()}  {args.out}")


if __name__ == "__main__":
    main()
