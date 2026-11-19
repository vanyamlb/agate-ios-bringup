#!/usr/bin/env python3
"""Append an agate G77 workaround entry to a copy of a valid AGFW v1 blob."""
from pathlib import Path
from struct import pack_into, unpack_from
import argparse
import hashlib

ENTRY_NAME = b"valhall-wa"
ENTRY_KIND = 4
AGATE_WA_SHA256 = "1a52a7f3c7c8b15e13e226d0956091621a83baafd80a3f93debb8271110e5951"


def append_workaround(base, firmware):
    if hashlib.sha256(firmware).hexdigest() != AGATE_WA_SHA256:
        raise ValueError("expected the original agate Android G77 workaround")
    if len(base) < 16:
        raise ValueError("truncated AGFW header")
    magic, version, count, total = unpack_from("<4sIII", base)
    if (magic, version, total) != (b"AGFW", 1, len(base)) or not 0 < count < 16:
        raise ValueError("unexpected AGFW v1 layout")
    end = 16 + 32 * count
    new_end = end + 32
    if total < new_end or total % 64:
        raise ValueError("no room for the extra firmware entry")
    for index in range(count):
        kind, _, length, offset, name = unpack_from("<IIII16s", base, 16 + 32 * index)
        if offset < new_end or offset > total or length > total - offset:
            raise ValueError("firmware descriptor overlaps table or lies outside AGFW")
        if kind == ENTRY_KIND or name.rstrip(b"\0") == ENTRY_NAME:
            raise ValueError("AGFW already includes a GPU workaround")
    if any(base[end:new_end]):
        raise ValueError("extra table slot is not zero padding")
    blob = bytearray(base)
    blob.extend(firmware)
    blob.extend(b"\0" * (-len(blob) % 64))
    pack_into("<II", blob, 8, count + 1, len(blob))
    pack_into("<IIII16s", blob, end, ENTRY_KIND, 0, len(firmware), total, ENTRY_NAME)
    return blob


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path)
    parser.add_argument("firmware", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    output = append_workaround(args.base.read_bytes(), args.firmware.read_bytes())
    with args.output.open("xb") as file:
        file.write(output)


if __name__ == "__main__":
    main()
