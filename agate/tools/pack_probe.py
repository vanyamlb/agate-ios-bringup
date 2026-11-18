#!/usr/bin/env python3
"""Pack a freestanding payload into an agate boot image's kernel slot.

Based on src/bringup/build_full_a.py. The kernel slot keeps its exact
compressed size (FEXTRA padding), so the header, ramdisk, DTB and AVB data
stay byte-identical. If the payload makes the stream too large, part of the
old kernel after the payload is zeroed (it is never executed).

The output is verified before it is written:
  - header and every byte outside the kernel slot equal the base image,
  - the kernel stream decompresses, keeps the ARM64 Image header,
    branches to the payload and carries the payload unchanged.
"""
import argparse
import hashlib
import struct
import zlib

ZERO_STEP = 0x10000


def parse_int(value):
    return int(value, 0)


def pack(raw, payload, off, zero_len):
    mod = bytearray(raw)
    mod[0:4] = struct.pack("<I", 0x14000000 | (off // 4))
    mod[off:off + len(payload)] = payload
    end = off + len(payload)
    zero_len = min(zero_len, len(mod) - end)
    mod[end:end + zero_len] = bytes(zero_len)
    co = zlib.compressobj(9, zlib.DEFLATED, -15)
    deflate = co.compress(bytes(mod)) + co.flush()
    return mod, deflate


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", required=True, help="known-good boot image")
    ap.add_argument("--payload", required=True, help="raw AArch64 payload")
    ap.add_argument("--out", required=True, help="output boot image")
    ap.add_argument("--payload-off", type=parse_int, default=0x1000)
    ap.add_argument("--expect-base-sha", help="refuse other base images")
    args = ap.parse_args()

    if args.out == args.base:
        raise SystemExit("refusing to overwrite the base image")
    base = open(args.base, "rb").read()
    payload = open(args.payload, "rb").read()
    base_sha = hashlib.sha256(base).hexdigest()
    if args.expect_base_sha and not base_sha.startswith(args.expect_base_sha):
        raise SystemExit(f"base sha256 {base_sha} does not match")
    if base[:8] != b"ANDROID!":
        raise SystemExit("not an Android boot image")
    kernel_size = struct.unpack_from("<I", base, 8)[0]
    page = struct.unpack_from("<I", base, 36)[0]
    header_version = struct.unpack_from("<I", base, 40)[0]
    if header_version != 2 or page != 2048:
        raise SystemExit(f"unexpected header v{header_version} page {page}")

    comp = base[page:page + kernel_size]
    raw = zlib.decompress(comp, 16 + zlib.MAX_WBITS)
    if raw[0x38:0x3c] != b"ARMd":
        raise SystemExit("ARM64 Image magic not found")
    if args.payload_off < 0x40 or args.payload_off % 4:
        raise SystemExit("bad payload offset")
    if args.payload_off + len(payload) > len(raw):
        raise SystemExit("payload does not fit")

    budget = kernel_size - 20  # gzip header (12 with XLEN) + footer (8)
    zero_len = 0
    mod, deflate = pack(raw, payload, args.payload_off, 0)
    if len(deflate) > budget:
        lo, hi = 1, (len(raw) - args.payload_off) // ZERO_STEP + 1
        while lo < hi:
            mid = (lo + hi) // 2
            _, d = pack(raw, payload, args.payload_off, mid * ZERO_STEP)
            if len(d) <= budget:
                hi = mid
            else:
                lo = mid + 1
        zero_len = lo * ZERO_STEP
        mod, deflate = pack(raw, payload, args.payload_off, zero_len)
    extra_len = budget - len(deflate)
    if not 0 <= extra_len <= 0xFFFF:
        raise SystemExit(f"cannot fit gzip stream: extra={extra_len}")

    header = (b"\x1f\x8b\x08\x04" + b"\x00" * 4 + b"\x02\x03"
              + struct.pack("<H", extra_len))
    footer = struct.pack("<II", zlib.crc32(mod) & 0xFFFFFFFF,
                         len(mod) & 0xFFFFFFFF)
    gz = header + b"\x00" * extra_len + deflate + footer
    assert len(gz) == kernel_size

    img = bytearray(base)
    img[page:page + kernel_size] = gz

    # Verification.
    assert len(img) == len(base)
    assert img[:page] == base[:page], "header changed"
    assert img[page + kernel_size:] == base[page + kernel_size:], \
        "data outside the kernel slot changed"
    check = zlib.decompress(bytes(img[page:page + kernel_size]),
                            16 + zlib.MAX_WBITS)
    assert check[0x38:0x3c] == b"ARMd"
    assert check[4:0x40] == raw[4:0x40], "Image header changed"
    assert struct.unpack_from("<I", check, 0)[0] == \
        0x14000000 | (args.payload_off // 4)
    assert check[args.payload_off:args.payload_off + len(payload)] == payload

    with open(args.out, "wb") as f:
        f.write(img)
    print(f"base     {base_sha}")
    print(f"payload  {len(payload)} B at Image+{args.payload_off:#x}, "
          f"sha256 {hashlib.sha256(payload).hexdigest()}")
    print(f"kernel   {kernel_size} B gzip, extra={extra_len}, "
          f"zeroed={zero_len:#x}")
    print(f"out      {hashlib.sha256(img).hexdigest()}  {args.out}")


if __name__ == "__main__":
    main()
