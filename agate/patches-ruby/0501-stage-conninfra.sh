#!/bin/bash
# Stage MediaTek's MT6893 conninfra platform code (GPL-2.0, from the Xiaomi 11T's own
# kernel tree) into bsd/dev/agate_conninfra/mtk/ for the Wi-Fi bring-up (0501).
# Nothing of it is kept in git: it is fetched at a pinned commit and checked by hash.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/kern/bsd_init.c ]] || exit 1

repo=https://raw.githubusercontent.com/xiaomi-mt6893-dev/kernel_xiaomi_mt6893
commit=aeb1327b1c73dfe71c4d0e184e5c1c419ee7291f
base=drivers/misc/mediatek/connectivity/conninfra
target=bsd/dev/agate_conninfra/mtk
[[ ! -e "$target" ]] || { echo "refusing to overwrite $target" >&2; exit 1; }
mkdir -p "$target"

fetch() {   # path-in-tree  sha256
    local name; name=$(basename "$1")
    curl -fsSL --retry 3 -o "$target/$name" "$repo/$commit/$base/$1"
    echo "$2  $target/$name" | shasum -a 256 -c - >/dev/null || {
        echo "conninfra source changed: $1" >&2; exit 1; }
}
fetch platform/mt6893/mt6893_pos.c                      fb998ea09e10f18006cabf8a0b2a3312cace979386d55b251e0b84679be2512f
fetch platform/mt6893/include/mt6893_pos.h              2268210d5268ce745488af1182900646a206bd946235af7a1ff74f59bcd220c6
fetch platform/mt6893/include/mt6893.h                  691b8011098e6ba5fe03a880d1caa31d5e060211c341d2bc8451be84f1f2e68e
fetch platform/mt6893/include/mt6893_consys_reg.h       09d2115a91fdd00b39e68a837c3eee45222e806a67a031a61deb96be3450484d
fetch platform/mt6893/include/mt6893_consys_reg_offset.h a31b9c743385283a60d3d78e3e99d178242d83412292f352e4fec2a63f994af0
fetch platform/include/consys_reg_base.h                5185ec00cb404d6adb16e9e2a74b617ddc1f49e41b99c7bfbf5af342222a5743
fetch include/conninfra.h                               f92c10e1c8ff3dac497ef0232b9fc38a63f6b68fdb0211199a3ec18fe69ffd07
echo "Staged MT6893 conninfra platform code ($commit) for agate"
