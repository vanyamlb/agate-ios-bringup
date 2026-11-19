#!/bin/bash
# Build the shim on macOS with Apple clang + Homebrew aarch64-elf-binutils.
#   brew install aarch64-elf-binutils ; bash agate/shim/build-mac.sh OUTDIR
set -euo pipefail
cd "$(dirname "$0")"
O=${1:-out}
mkdir -p "$O"
CF=(-target aarch64-none-elf -O2 -ffreestanding -fno-builtin -nostdlib -fpie -mgeneral-regs-only
    -mstrict-align -fno-stack-protector -Wall -Wextra -Werror)
clang "${CF[@]}" -c start.S -o "$O/start.o"
clang "${CF[@]}" -c shim.c -o "$O/shim.o"
if aarch64-elf-readelf -rW "$O/start.o" "$O/shim.o" | grep -E 'ABS64|ABS32|GOT|GLOB_DAT'; then
	echo "error: absolute or GOT relocations in the shim" >&2; exit 1
fi
aarch64-elf-ld -static -nostdlib --no-dynamic-linker --build-id=none -T link.ld -o "$O/shim.elf" "$O/start.o" "$O/shim.o"
aarch64-elf-objcopy -O binary "$O/shim.elf" "$O/shim.bin"
entry=$(aarch64-elf-nm "$O/shim.elf" | awk '$3=="_start"{print $1}')
[ "$entry" = "0000000040081000" ] || { echo "error: _start at $entry" >&2; exit 1; }
size=$(wc -c < "$O/shim.bin" | tr -d ' ')
[ "$size" -lt 40960 ] || { echo "error: shim is $size bytes" >&2; exit 1; }
shasum -a 256 "$O/shim.bin"
echo "shim.bin: $size bytes"
