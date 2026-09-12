#!/bin/sh
# Fetch the pinned Seekwave SWT6621S driver tree (Wi-Fi + BT, GPLv2) and stage it into the given
# dir as the DKMS source. Used by build-image.sh (staged into the image) and rk35xx-update (straight
# into /usr/src on the live box). Needs network + curl + tar.
#   usage: fetch-seekwave-src.sh <src-dir>
set -e
DIR="${1:?usage: fetch-seekwave-src.sh <src-dir>}"

# pinned commit of https://github.com/retro98boy/seekwave-swt6621s (kickpi-k3b-sdio-uart branch)
SHA=b1b15016119cb21965fc64dd374e42f46f011bb4

PATCHES="$(cd "$(dirname "$0")/../../patches/seekwave-swt6621s" && pwd)"

# Build beside the staged tree and swap only on success. A box whose only network comes from this
# driver has to be able to rebuild from the tree it already has, so a failed fetch or a patch that
# does not apply must leave that tree untouched rather than half-replaced.
NEW="$DIR.new"
trap 'rm -rf "$NEW"' EXIT
rm -rf "$NEW"; mkdir -p "$NEW"
curl -fsSL "https://codeload.github.com/retro98boy/seekwave-swt6621s/tar.gz/$SHA" \
  | tar -xz -C "$NEW" --strip-components=1
# tar can exit 0 on a truncated stream, so check for something the archive must contain
[ -f "$NEW/dkms.conf" ] || { echo "fetch-seekwave-src: incomplete download" >&2; exit 1; }

for p in "$PATCHES"/*.patch; do
  patch -p1 -d "$NEW" < "$p"
done

rm -rf "$DIR"; mv "$NEW" "$DIR"
trap - EXIT
# the repo's own dkms.conf drives the build (package seekwave-swt6621s/1.0.0: skw_sdio_lite,
# swt6621s_wifi, skwbt); firmware ships separately from firmware/common/seekwave-fw/
