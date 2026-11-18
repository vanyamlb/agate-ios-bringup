#!/bin/sh
# Build the agate XNU shim as a flat binary (out/shim.bin).
# Needs an AArch64 GNU toolchain: CROSS=aarch64-linux-gnu- by default.
set -eu
cd "$(dirname "$0")"
CROSS=${CROSS:-aarch64-linux-gnu-}
CFLAGS="-O2 -ffreestanding -fno-builtin -nostdlib -fpie -mgeneral-regs-only \
-mstrict-align -fno-stack-protector -fno-tree-loop-distribute-patterns \
-fno-asynchronous-unwind-tables -Wall -Wextra -Werror"

rm -rf out
mkdir -p out
${CROSS}gcc $CFLAGS -c start.S -o out/start.o
${CROSS}gcc $CFLAGS -c shim.c -o out/shim.o

# The shim must run wherever LK puts it: PC-relative code only.
if ${CROSS}readelf -rW out/start.o out/shim.o | grep -E 'ABS64|ABS32|GOT|GLOB_DAT'; then
	echo "error: absolute or GOT relocations in the shim" >&2
	exit 1
fi

${CROSS}ld -static -nostdlib --no-dynamic-linker --build-id=none -T link.ld \
	-o out/shim.elf out/start.o out/shim.o
${CROSS}objcopy -O binary out/shim.elf out/shim.bin
${CROSS}objdump -d out/shim.elf > out/shim.dis

entry=$(${CROSS}nm out/shim.elf | awk '$3=="_start"{print $1}')
[ "$entry" = "0000000040081000" ] || { echo "error: _start at $entry" >&2; exit 1; }

size=$(wc -c < out/shim.bin)
[ "$size" -lt 40960 ] || { echo "error: shim is $size bytes" >&2; exit 1; }
sha256sum out/shim.bin | tee out/SHA256SUMS
echo "shim.bin: $size bytes, entry $entry"
