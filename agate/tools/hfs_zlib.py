#!/usr/bin/env python3
"""Make every HFS-compressed file of a mounted iOS root readable by the agate
kernel, and verify it.

  sudo hfs_zlib.py recompress ROOT     # macOS, ROOT mounted read-write, owners on
  hfs_zlib.py verify ROOT              # read-only check

The agate kernel (patch 0092) decodes decmpfs types 3 and 4 (zlib) and 9
(raw after a 0xCC byte). `ditto --hfsCompression` keeps the source's own
compression for some files (LZVN 7/8, LZBITMAP 13/14, LZFSE 11/12), which the
open-source kernel cannot read. `recompress` rewrites those files in place as
type 4 (zlib, 64 KiB chunks in the resource fork), keeping the inode (so hard
links stay shared), owner, mode, flags, other xattrs and times.

`verify` decodes every compressed file exactly as the kernel does and compares
the result with what macOS reads, so a format mistake shows up here instead
of on the phone.
"""
import ctypes
import ctypes.util
import os
import stat
import struct
import sys
import zlib

LIBC = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
for fn, argt, rest in (
        ('getxattr', [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_uint32, ctypes.c_int], ctypes.c_ssize_t),
        ('setxattr', [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                      ctypes.c_uint32, ctypes.c_int], ctypes.c_int),
        ('removexattr', [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int], ctypes.c_int),
        ('listxattr', [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int], ctypes.c_ssize_t),
        ('chflags', [ctypes.c_char_p, ctypes.c_uint32], ctypes.c_int)):
    getattr(LIBC, fn).argtypes = argt
    getattr(LIBC, fn).restype = rest

NOFOLLOW, SHOWCOMPRESSION = 0x0001, 0x0020
UF_COMPRESSED = 0x20
DECMPFS = b'com.apple.decmpfs'
RSRC = b'com.apple.ResourceFork'
MAGIC = 0x636d7066            # 'fpmc'
CHUNK = 0x10000
SUPPORTED = (3, 4, 9)


def oserr(what, path):
    e = ctypes.get_errno()
    raise OSError(e, f'{what}: {os.strerror(e)}', path)


def getx(path, name):
    p = os.fsencode(path)
    n = LIBC.getxattr(p, name, None, 0, 0, NOFOLLOW | SHOWCOMPRESSION)
    if n < 0:
        return None
    buf = ctypes.create_string_buffer(n)
    n = LIBC.getxattr(p, name, buf, n, 0, NOFOLLOW | SHOWCOMPRESSION)
    if n < 0:
        oserr('getxattr', path)
    return buf.raw[:n]


def listx(path):
    p = os.fsencode(path)
    n = LIBC.listxattr(p, None, 0, NOFOLLOW)
    if n <= 0:
        return []
    buf = ctypes.create_string_buffer(n)
    n = LIBC.listxattr(p, buf, n, NOFOLLOW)
    if n < 0:
        oserr('listxattr', path)
    return [x for x in buf.raw[:n].split(b'\0') if x]


def setx(path, name, data):
    if LIBC.setxattr(os.fsencode(path), name, data, len(data), 0, NOFOLLOW | SHOWCOMPRESSION) != 0:
        oserr('setxattr ' + name.decode(), path)


def chflags(path, flags):
    if LIBC.chflags(os.fsencode(path), flags) != 0:
        oserr('chflags', path)


def cmp_type(path):
    h = getx(path, DECMPFS)
    if h is None or len(h) < 16:
        return None, None
    magic, typ, size = struct.unpack('<IIQ', h[:16])
    return (typ, size) if magic == MAGIC else (None, None)


def resource_fork(chunks):
    """Classic resource fork holding one 'cmpf' resource (the decmpfs type 4 layout)."""
    n = len(chunks)
    table = struct.pack('<I', n)
    off = 4 + 8 * n
    body = b''
    for c in chunks:
        table += struct.pack('<II', off, len(c))
        off += len(c)
        body += c
    res = table + body
    data = struct.pack('>I', len(res)) + res
    data_off, data_len = 0x100, len(data)
    map_off, map_len = data_off + data_len, 0x32
    hdr = struct.pack('>IIII', data_off, map_off, data_len, map_len)
    # Same map as Apple's (ditto): the header copy at the start of the map is zero.
    rmap = (b'\0' * 16 + b'\0' * 4 + b'\0' * 2 + b'\0' * 2 + struct.pack('>HH', 28, map_len)
            + struct.pack('>H4sHH', 0, b'cmpf', 0, 10)
            + struct.pack('>HHII', 1, 0xFFFF, 0, 0))
    assert len(rmap) == map_len
    return hdr + b'\0' * (0x100 - 16) + data + rmap


def zlib_chunks(data):
    out = []
    for i in range(0, max(len(data), 1), CHUNK):
        raw = data[i:i + CHUNK]
        z = zlib.compress(raw, 9)
        out.append(z if len(z) < len(raw) + 1 else b'\xff' + raw)
    return out


def recompress_one(path):
    st = os.lstat(path)
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) != st.st_size:
        raise OSError(f'short read {len(data)} != {st.st_size}', path)
    others = {}
    for b in listx(path):
        if b not in (DECMPFS, RSRC):
            others[b] = getx(path, b)
    # Clearing UF_COMPRESSED makes the kernel decompress into the data fork
    # (same inode); then rebuild the file as zlib type 4.
    chflags(path, st.st_flags & ~UF_COMPRESSED)
    for b in (DECMPFS, RSRC):
        LIBC.removexattr(os.fsencode(path), b, NOFOLLOW | SHOWCOMPRESSION)
    setx(path, RSRC, resource_fork(zlib_chunks(data)))
    setx(path, DECMPFS, struct.pack('<IIQ', MAGIC, 4, len(data)))
    os.truncate(path, 0)
    for b, v in others.items():
        setx(path, b, v)
    os.chown(path, st.st_uid, st.st_gid, follow_symlinks=False)
    os.chmod(path, stat.S_IMODE(st.st_mode))
    chflags(path, st.st_flags | UF_COMPRESSED)
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)


def unpack(unit, want):
    if not unit:
        raise ValueError('empty unit')
    if unit[0] & 0x0F == 0x0F:
        return unit[1:1 + want]
    return zlib.decompressobj().decompress(unit, want)


def kernel_decode(path, typ, size):
    """What patch 0092 does for types 3, 4 and 9."""
    h = getx(path, DECMPFS)
    if typ == 3:
        return unpack(h[16:], size)
    if typ == 9:
        if len(h) != 17 + size or h[16] != 0xCC:
            raise ValueError('bad type 9 attribute')
        return h[17:]
    rf = getx(path, RSRC)
    base = struct.unpack('>I', rf[:4])[0] + 4
    n = struct.unpack('<I', rf[base:base + 4])[0]
    need = (size + CHUNK - 1) // CHUNK
    if n < need:
        raise ValueError(f'{n} chunks < {need}')
    out = bytearray()
    for k in range(need):
        off, csz = struct.unpack('<II', rf[base + 4 + 8 * k:base + 12 + 8 * k])
        want = min(CHUNK, size - k * CHUNK)
        part = unpack(rf[base + off:base + off + csz], want)
        if len(part) != want:
            raise ValueError(f'chunk {k}: {len(part)} != {want}')
        out += part
    return bytes(out)


def compressed_files(root):
    seen = set()
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            st = os.lstat(p)
            if not stat.S_ISREG(st.st_mode) or not st.st_flags & UF_COMPRESSED:
                continue
            if (st.st_dev, st.st_ino) in seen:
                continue
            seen.add((st.st_dev, st.st_ino))
            yield p


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('recompress', 'verify'):
        sys.exit(__doc__)
    mode, root = sys.argv[1], sys.argv[2]
    counts, done, bad = {}, 0, 0
    for p in compressed_files(root):
        typ, size = cmp_type(p)
        counts[typ] = counts.get(typ, 0) + 1
        if mode == 'recompress':
            if typ not in SUPPORTED:
                recompress_one(p)
                done += 1
                if done % 200 == 0:
                    print(f'recompressed {done}', flush=True)
            continue
        try:
            if typ not in SUPPORTED:
                raise ValueError(f'unsupported type {typ}')
            ok = kernel_decode(p, typ, size) == open(p, 'rb').read()
        except (ValueError, OSError, zlib.error) as e:
            ok = False
            print('ERROR', p, e)
        if not ok:
            bad += 1
            print('MISMATCH', typ, p)
    print('types', counts)
    if mode == 'recompress':
        print('recompressed to zlib:', done)
    else:
        print('verify: mismatches', bad)
        sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
