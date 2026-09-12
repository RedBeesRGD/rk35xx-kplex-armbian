#!/usr/bin/env bash
# Rebuild every board's firmware/ artifacts, then say whether any moved.
#
# Run it before pushing: a dirty firmware/ afterwards means a board.patch, a uboot.patch or a
# factory blob changed and the shipped artifact had not caught up.
set -euo pipefail

cd "$(dirname "$0")"
./build-firmware.sh

echo
if git diff --quiet -- firmware/ && git diff --cached --quiet -- firmware/; then
	echo "firmware/ is up to date"
else
	echo "firmware/ changed — commit these or find out why they drifted:"
	git status --short -- firmware/
fi
