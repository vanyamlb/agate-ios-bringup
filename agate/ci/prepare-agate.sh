#!/bin/sh
# Prepare the agate XNU patchset.
#
# Starts from the full, hash-verified ruby set (ci/prepare-baseline.sh with the
# public upstream), then keeps only the sweet baseline (0001-0079, including
# ci/baseline-changes.patch: early console at 0x7cdfc000 / stride 4352) plus
# ruby 0080-0083 - the set ruby's first MTK boots used (config/0084.env minus
# the autoswipe and Goodix touch patches). Every later ruby patch drives
# MT6877 hardware (USB, PMIC wrapper, EINT, keys, battery) and is dropped.
#
# Usage: sh agate/ci/prepare-agate.sh DEST
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DEST=${1:-base}

ALLOW_PUBLIC_UPSTREAM=1 \
PATCHSET_SHA256=d87e666ff903ad8dc214773495feac827558ab53bf5b8fd3edfc30734c19ff71 \
	sh "$ROOT/ci/prepare-baseline.sh" "$DEST"

for f in "$DEST"/xnu/patches/*.patch; do
	n=$(basename "$f" | cut -c1-4)
	if [ "$n" -ge 84 ] 2>/dev/null || [ "$(expr "$n" \> 0083)" = 1 ]; then
		rm -f "$f"
	fi
done

count=$(ls "$DEST"/xnu/patches | wc -l | tr -d ' ')
echo "agate patchset files: $count"
ls "$DEST"/xnu/patches | tail -6
[ "$count" = 86 ] || { echo "expected 86 files (82 baseline + 0080-0083)" >&2; exit 1; }
python3 "$ROOT/ci/patchset_hash.py" "$DEST/xnu/patches"
