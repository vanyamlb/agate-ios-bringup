#!/bin/sh
# Build the agate display probe as a flat binary (out/probe.bin).
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
${CROSS}gcc $CFLAGS -c probe.c -o out/probe.o

# The probe must run wherever LK puts it: PC-relative code only.
if ${CROSS}readelf -rW out/start.o out/probe.o | grep -E 'ABS64|ABS32|GOT|GLOB_DAT'; then
	echo "error: absolute or GOT relocations in the probe" >&2
	exit 1
fi

${CROSS}ld -static -nostdlib --no-dynamic-linker --build-id=none -T link.ld \
	-o out/probe.elf out/start.o out/probe.o
${CROSS}objcopy -O binary out/probe.elf out/probe.bin
${CROSS}objdump -d out/probe.elf > out/probe.dis

entry=$(${CROSS}nm out/probe.elf | awk '$3=="_start"{print $1}')
[ "$entry" = "0000000040081000" ] || { echo "error: _start at $entry" >&2; exit 1; }

size=$(wc -c < out/probe.bin)
[ "$size" -lt 65536 ] || { echo "error: probe is $size bytes" >&2; exit 1; }
sha256sum out/probe.bin | tee out/SHA256SUMS
echo "probe.bin: $size bytes, entry $entry"
