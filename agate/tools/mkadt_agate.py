#!/usr/bin/env python3
"""Build the minimal Apple Device Tree for the agate (Xiaomi 11T, MT6893) XNU.

Derived from MakrSas/ios-topaz tools/mkadt.py (fetched at the pinned
baseline commit; its adt.py does the serialisation). Every address comes from
the agate live FDT (agate/README.md). UFS: /sweet-ufs is only added with --ufs. The driver then reaches storage only
through rd=ufsroot0 or agateufsprobe=1, and writes only with ufsrw=1.
Deliberately absent:
  - /product (needs the D22AP tree from an IPSW; not needed for kernel boot).

Usage: mkadt_agate.py --topaz DIR OUT.adt [--dump]
"""
import argparse
import hashlib
import os
import struct
import sys

PHYS_BASE = 0x140000000  # 2 GiB above the dramc-rk0 marker, below rk1
MEM_SIZE = 0x80000000
SOC_BASE = 0x01000000    # /arm-io children are relative to this (must be != 0)

GICD, GICD_SIZE = 0x0c000000, 0x40000
GICR, GICR_SIZE = 0x0c040000, 0x200000
VTIMER_INTID = 27        # PPI 11
TIMEBASE = 13000000

# Visible buffer after the shim moves OVL0 layer 1 (inside mblock-20).
FB, FB_SIZE = 0x7cdfc000, 0x7d800000 - 0x7cdfc000
FB_W, FB_H, FB_STRIDE = 1080, 2400, 4352

UFS, UFS_SIZE = 0x11270000, 0x4000   # ufshci@11270000, reg 0x2300 rounded to a 16K page

A55_MPIDRS = (0x000, 0x100, 0x200, 0x300)
A78_MPIDRS = (0x400, 0x500, 0x600)   # 0x700 stays with the shim's frame kicker
SWEET_ECID = 0x4147415445000001  # 'AGATE' + 1, synthetic
BOOT_MANIFEST_HASH = hashlib.sha384(b'agate boot manifest').digest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--topaz', required=True, help='ios-topaz checkout (tools/adt.py)')
    ap.add_argument('out')
    ap.add_argument('--dump', action='store_true')
    ap.add_argument('--ufs', action='store_true', help='add /sweet-ufs (UFS host)')
    ap.add_argument('--gamut', help="override /product artwork-display-gamut (e.g. sRGB)")
    ap.add_argument('--big', type=int, default=0, choices=range(4),
                    help='also list N Cortex-A78 cores (MPIDR 0x400..); 0x700 runs the shim kicker')
    ap.add_argument('--d22ap', help='iPhone X device tree (DeviceTree.d22ap.im4p payload, '
                    'decompressed): its /product node feeds MobileGestalt')
    a = ap.parse_args()
    sys.path.insert(0, os.path.join(a.topaz, 'tools'))
    import adt  # noqa: E402

    u32 = lambda *v: struct.pack('<%dI' % len(v), *v)
    u64 = lambda *v: struct.pack('<%dQ' % len(v), *v)
    cstr = lambda s: s.encode() + b'\0'
    phandle = iter(range(1, 1000))
    ph = lambda: ('AAPL,phandle', u32(next(phandle)))

    def node(name, props=(), children=()):
        n = adt.Node()
        n.props = [('name', 0, cstr(name))] + [(k, 0, v) for k, v in props]
        n.children = list(children)
        return n

    chosen = node('chosen', [
        ph(),
        ('dram-base', u64(PHYS_BASE)),
        ('dram-size', u64(MEM_SIZE)),
        ('random-seed', os.urandom(64)),
        ('debug-enabled', u32(1)),
        ('firmware-version', cstr('agate-shim')),
        ('system-firmware-version', cstr('agate-shim')),
        ('boot-manifest-hash', BOOT_MANIFEST_HASH),
        ('crypto-hash-method', cstr('sha2-384')),
        ('display-scale', u32(3)),
        ('unique-chip-id', struct.pack('<Q', SWEET_ECID)),
        ('chip-id', u32(0x8015)),
        ('certificate-production-status', u32(0)),
        ('effective-production-status-ap', u32(0)),
        ('certificate-security-mode', u32(1)),
        ('effective-security-mode-sep', u32(1)),
    ], [node('memory-map', [ph()]),
        node('asmb', [ph(), ('lp-sip0', u64(0x6f)), ('lp-sip1', u32(1))])])

    cpu_nodes = []
    for i, mpidr in enumerate(A55_MPIDRS + A78_MPIDRS[:a.big]):
        big = mpidr in A78_MPIDRS
        cpu_nodes.append(node(f'cpu{i}', [
            ph(),
            ('device_type', cstr('cpu')),
            # SweetCPU matches 'qcom,kryo470' (IONameMatch): every core needs it
            ('compatible', (cstr('arm,cortex-a78') if big else cstr('arm,cortex-a55')) + cstr('qcom,kryo470') + cstr('ARM,v8')),
            ('reg', u32(mpidr)),
            ('cpu-id', u32(i)),
            ('cluster-id', u32(0)),
            ('cluster-type', u32(0)),
            ('die-cluster-id', u32(0)),
            ('cluster-core-id', u32(i)),
            ('l2-cache-id', u32(0)),
            ('l3-cache-id', u32(0)),
            ('state', cstr('running' if i == 0 else 'stopped')),
            ('timebase-frequency', u32(TIMEBASE)),
            ('clock-frequency', u32(2600000000 if big else 2000000000)),
            ('bus-frequency', u32(100000000)),
            ('memory-frequency', u32(1866000000)),
            ('peripheral-frequency', u32(TIMEBASE)),
            ('fixed-frequency', u32(TIMEBASE)),
        ]))
    cpus = node('cpus', [ph(), ('#address-cells', u32(1)), ('#size-cells', u32(0))], cpu_nodes)

    gic = node('gic', [
        ph(),
        ('compatible', cstr('arm,gic-v3')),
        ('interrupt-controller', b''),
        ('virtual-timer-intid', u32(VTIMER_INTID)),
        ('reg', u64(GICD - SOC_BASE, GICD_SIZE, GICR - SOC_BASE, GICR_SIZE)),
    ])
    arm_io = node('arm-io', [
        ph(),
        ('device_type', cstr('sweet-io')),
        ('compatible', cstr('sweet-io') + cstr('arm-io')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
        ('ranges', u64(0, SOC_BASE, 0x100000000 - SOC_BASE)),
    ], [gic,
        node('wdt', [ph(), ('no-pmu', u32(1))]),
        node('disp0', [
            ph(),
            ('device_type', cstr('display-subsystem')),
            ('compatible', cstr('sweet,display')),
            ('canvas-width', u32(1125)),
            ('canvas-height', u32(2436)),
        ])])

    fbcon = node('sweet-fbcon', [
        ph(),
        ('reg', u64(FB, FB_SIZE)),
        ('width', u32(FB_W)),
        ('height', u32(FB_H)),
        ('stride', u32(FB_STRIDE)),
    ])
    defaults = node('defaults', [ph(), ('no-effaceable-storage', u32(1))])
    buttons = node('buttons', [
        ph(),
        ('button-names', cstr('volup') + cstr('voldown') + cstr('hold')),
        ('home-button-type', u32(2)),
        ('opposed-power-vol-buttons', u32(1)),
    ])

    product = []
    if a.d22ap:
        d22, _ = adt.parse(open(a.d22ap, 'rb').read())
        for c in d22.children:
            if dict((k, v) for k, f, v in c.props).get('name') == b'product\0':
                # as ios-topaz: drop syscfg placeholders (flag set) and node bookkeeping
                props = [(k, v) for k, f, v in c.props if not f and k not in ('name', 'AAPL,phandle')]
                if a.gamut:
                    # the CPU compositor only shows 8-bit BGRA: a P3 panel makes
                    # WebKit and others render 10-bit 'w30r' surfaces (white pages)
                    props = [(k, cstr(a.gamut) if k == 'artwork-display-gamut' else v)
                             for k, v in props]
                product = [node('product', [ph()] + props)]
        if not product:
            sys.exit(f'{a.d22ap}: no /product node')

    root = node('device-tree', [
        ph(),
        ('compatible', cstr('D22AP') + cstr('iPhone10,3') + cstr('xiaomi,agate')
         + cstr('xiaomi,sweet') + cstr('mediatek,mt6893') + cstr('AppleARM')),
        ('model', cstr('iPhone10,3')),
        ('target-type', cstr('D22')),
        ('target-sub-type', cstr('D22AP')),
        ('manufacturer', cstr('Apple Inc.')),
        ('#address-cells', u32(2)),
        ('#size-cells', u32(2)),
    ], [chosen, defaults, cpus, arm_io, fbcon, buttons] + product + ([node('sweet-ufs', [
        ph(),
        ('compatible', cstr('mediatek,ufshci')),
        ('reg', u64(UFS, UFS_SIZE)),
    ])] if a.ufs else []))

    blob = adt.serialize(root)
    open(a.out, 'wb').write(blob)
    if a.dump:
        adt.dump(adt.parse(blob)[0])
    print(f'{a.out}: {len(blob)} bytes', file=sys.stderr)


if __name__ == '__main__':
    main()
