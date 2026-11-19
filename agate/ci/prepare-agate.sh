#!/bin/sh
# Prepare the agate XNU patchset.
#
# Starts from the full, hash-verified ruby set (ci/prepare-baseline.sh with the
# public upstream), then keeps only the sweet baseline (0001-0079, including
# ci/baseline-changes.patch: early console at 0x7cdfc000 / stride 4352) plus
# ruby 0080-0084 - the set ruby's first MTK boots used (config/0084.env minus
# the Goodix touch patch; 0084 is the synthetic unlock swipe). Every later ruby patch drives
# MT6877 hardware (USB, PMIC wrapper, EINT, keys, battery) and is dropped.
#
# Then adds agate/patches/*.patch (e.g. 0090: read-only UFS probe).
#
# Usage: sh agate/ci/prepare-agate.sh DEST
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DEST=${1:-base}

ALLOW_PUBLIC_UPSTREAM=1 \
PATCHSET_SHA256=d87e666ff903ad8dc214773495feac827558ab53bf5b8fd3edfc30734c19ff71 \
	sh "$ROOT/ci/prepare-baseline.sh" "$DEST"

# AGATE_BASE=ruby keeps the whole ruby set (0001-0334: USB, PMIC, EINT, ...;
# every ruby driver is boot-arg gated) and takes agate/patches-ruby/, the
# agate patches rebased onto it.
AGATE_BASE=${AGATE_BASE:-sweet}
if [ "$AGATE_BASE" = ruby ]; then
	cp "$ROOT"/agate/patches-ruby/*.patch "$DEST/xnu/patches/"
	python3 "$ROOT/ci/normalize_lf.py" "$DEST/xnu/patches"
	count=$(ls "$DEST"/xnu/patches | wc -l | tr -d ' ')
	expected=$((305 + $(ls "$ROOT"/agate/patches-ruby/*.patch | wc -l)))
	echo "agate-on-ruby patchset files: $count"
	[ "$count" = "$expected" ] || { echo "expected $expected files" >&2; exit 1; }
	python3 "$ROOT/ci/patchset_hash.py" "$DEST/xnu/patches"
	exit 0
fi

for f in "$DEST"/xnu/patches/*.patch; do
	n=$(basename "$f" | cut -c1-4)
	# 0084: ruby's synthetic bottom-edge swipe (software only, boot-arg gated)
	[ "$n" = 0084 ] && continue
	if [ "$n" -ge 84 ] 2>/dev/null || [ "$(expr "$n" \> 0083)" = 1 ]; then
		rm -f "$f"
	fi
done

# agate's own patches (0090+) go after ruby 0080-0083.
cp "$ROOT"/agate/patches/*.patch "$DEST/xnu/patches/"
python3 "$ROOT/ci/normalize_lf.py" "$DEST/xnu/patches"
for p in "$ROOT"/agate/patches/*.patch; do
	git -C "$DEST" apply --stat "xnu/patches/$(basename "$p")" >/dev/null ||
		{ echo "malformed agate patch: $p" >&2; exit 6; }
done

count=$(ls "$DEST"/xnu/patches | wc -l | tr -d ' ')
echo "agate patchset files: $count"
ls "$DEST"/xnu/patches | tail -6
expected=$((87 + $(ls "$ROOT"/agate/patches/*.patch | wc -l)))
[ "$count" = "$expected" ] || { echo "expected $expected files (82 baseline + 0080-0084 + agate)" >&2; exit 1; }
python3 "$ROOT/ci/patchset_hash.py" "$DEST/xnu/patches"
