#!/bin/bash
# Build the agate iOS root on macOS: a trimmed, HFS-compressed, case-sensitive
# journaled HFS+ volume (no partition map) sized for the free tail of the
# agate `super` partition. Run as root (owners must be preserved):
#
#   sudo bash mkroot_agate.sh OS.dmg SYSTEMOS.dmg APPOS.dmg OUT.sparseimage TOPAZ_DIR [SIZE_MB]
#
# Mirrors ios-topaz tools/mkiosroot.sh (cryptex layout, dyld hard links, logd
# stores, plain system keybag) and then runs its tools/sweet-root-tweaks.py.
# Only the OUT image is written; the IPSW images are mounted read-only.
set -euo pipefail

[[ $# -ge 5 ]] || { sed -n '2,11p' "$0"; exit 2; }
[[ $(id -u) == 0 ]] || { echo "run with sudo" >&2; exit 2; }
os_dmg=$1 sys_dmg=$2 app_dmg=$3 out=$4 topaz=$5 size=${6:-5000}
here=$(cd "$(dirname "$0")" && pwd)
[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
[[ -f $topaz/tools/sweet-root-tweaks.py ]] || { echo "no ios-topaz tools in $topaz" >&2; exit 1; }

work=$(mktemp -d /private/tmp/agate-root.XXXXXX)
attached=()
cleanup() {
	for m in "$work"/m-* "$work/root"; do
		[[ -d $m ]] && mount | grep -q " on $m " && umount "$m" 2>/dev/null || true
	done
	for d in "${attached[@]}"; do hdiutil detach -quiet "$d" 2>/dev/null || true; done
	rmdir "$work"/m-* "$work/root" "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Attach an IPSW image read-only and mount its APFS volume with owners on.
mount_ro() {
	local img=$1 mnt=$2 out dev
	out=$(hdiutil attach -readonly -nobrowse -noverify -nomount "$img")
	attached+=("$(echo "$out" | awk 'NR==1{print $1}')")
	dev=$(echo "$out" | awk '/41504653/{print $1}' | tail -1)
	[[ -n $dev ]] || { echo "no APFS volume in $img" >&2; exit 1; }
	mkdir -p "$mnt"
	mount_apfs -o rdonly,nobrowse "$dev" "$mnt"
	echo "mounted $img ($dev) at $mnt"
}
mount_ro "$os_dmg" "$work/m-os"
mount_ro "$sys_dmg" "$work/m-sys"
mount_ro "$app_dmg" "$work/m-app"
[[ $(stat -f %u "$work/m-os/private/var/root" 2>/dev/null || echo x) == 0 ]] ||
	{ echo "owners are not visible on the OS volume" >&2; exit 1; }

hdiutil create -size "${size}m" -type SPARSE -layout NONE \
	-fs "Case-sensitive Journaled HFS+" -volname iOSRoot "$out"
out_img=$out
[[ -e $out_img ]] || out_img="$out.sparseimage"
dev=$(hdiutil attach -owners on -nobrowse -nomount "$out_img" | awk 'NR==1{print $1}')
attached+=("$dev")
mkdir -p "$work/root"
mount -t hfs -o owners "$dev" "$work/root"
echo "building into $out_img ($dev), ${size} MiB"

r=$work/root
python3 -I "$here/copy_trim.py" "$work/m-os" "$r"
python3 -I "$here/copy_trim.py" "$work/m-sys" "$r/private/preboot/Cryptexes/OS" --cryptex
python3 -I "$here/copy_trim.py" "$work/m-app" "$r/private/preboot/Cryptexes/App" --cryptex
df -m "$r" | tail -1

# Shared cache where dyld looks at ignition level 1: hard links.
dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
mkdir -p "$r/System/Library/Caches/com.apple.dyld"
for f in "$r/$dsc"/*; do
	ln "$f" "$r/System/Library/Caches/com.apple.dyld/${f##*/}"
done
# Cryptex files without a counterpart in the OS root (dyld does not search
# the cryptexes at ignition level 1).
for c in OS App; do
	(cd "$r/private/preboot/Cryptexes/$c" && find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if [[ ! -e $r/$f && ! -L $r/$f ]]; then
			mkdir -p "$r/$(dirname "$f")"
			src="$r/private/preboot/Cryptexes/$c/$f"
			if [[ -L $src ]]; then cp -P "$src" "$r/$f"; else ln "$src" "$r/$f"; fi
		fi
	done
done

# logd stores and the plain-plist system keybag (as mkiosroot.sh).
db="$r/private/var/db"
install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
	install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
done
install -d -m 0700 -o 0 -g 0 "$r/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' >"$r/private/var/keybags/systembag.kb"
chown 0:0 "$r/private/var/keybags/systembag.kb"
chmod 0600 "$r/private/var/keybags/systembag.kb"

python3 -I "$topaz/tools/sweet-root-tweaks.py" "$r"

sync
echo "== agate iOS root"
df -m "$r" | tail -1
umount "$r"
fsck_hfs -fn "$dev" || echo "fsck_hfs reported problems" >&2
echo "done: $out_img"
