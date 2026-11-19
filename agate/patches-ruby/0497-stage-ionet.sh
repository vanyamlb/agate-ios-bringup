#!/bin/bash
# Stage Apple's open source IONetworkingFamily for agate's built-in network
# stack (iokit/sweet_ionet): IONetworkStack, IONetworkController,
# IOEthernetController/Interface, so configd sees a real Ethernet interface.
# dxb runs patches/*.sh from the XNU source root before applying *.patch.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ "${MACOS_VERSION:-}" == 13.5 ]] || {
    echo 'agate IONetworkingFamily integration requires xnu-8796.141.3 (macOS 13.5)' >&2
    exit 1
}
[[ -f iokit/KernelConfigTables.cpp ]] || exit 1

# IONetworkingFamily-170.140.2 is paired with xnu-8796.141.3 in Apple's
# macos-135 release.json. Fetch the immutable commit, never a moving tag.
ionet_sha=f9f7e57b2132b82de09a26ddcbf56fd8125b4933
ionet_tmp=$(mktemp -d)
trap 'rm -rf "$ionet_tmp"' EXIT
git init -q "$ionet_tmp"
git -C "$ionet_tmp" fetch -q --depth 1 \
    https://github.com/apple-oss-distributions/IONetworkingFamily "$ionet_sha"
git -C "$ionet_tmp" checkout -q FETCH_HEAD
[[ "$(git -C "$ionet_tmp" rev-parse HEAD)" == "$ionet_sha" ]]

target=iokit/sweet_ionet
[[ ! -e "$target" ]] || { echo "refusing to overwrite $target" >&2; exit 1; }
mkdir -p "$target/include/IOKit/network"
# Preserve upstream copyright/license headers; no downloaded sources in git.
cp "$ionet_tmp"/*.cpp "$ionet_tmp"/*.h "$ionet_tmp/APPLE_LICENSE" "$target/"
# The sources include their public headers as <IOKit/network/...>.
cp "$ionet_tmp"/*.h "$target/include/IOKit/network/"

# Kernel builds use -nostdinc; IONetworkController.cpp needs the SDK's macros.
ionet_sdk=$(xcrun --sdk macosx --show-sdk-path)
cp "$ionet_sdk/usr/include/TargetConditionals.h" "$target/"
echo "Staged IONetworkingFamily-170.140.2 ($ionet_sha) for agate"
