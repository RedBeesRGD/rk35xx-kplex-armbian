#!/bin/sh
# Collect HS86 Mini 13 factory evidence while booted from SD. Reads the eMMC, never writes it.
# Run on the box: sudo sh collect-hs86.sh — output lands in hs86-evidence/ beside this script.
set -u

OUT="$(cd "$(dirname "$0")" && pwd)/hs86-evidence"
mkdir -p "$OUT" && cd "$OUT" || exit 1

EMMC=$(ls /dev/mmcblk*boot0 2>/dev/null | sed 's/boot0$//' | head -n1)
[ -n "$EMMC" ] || { echo "no eMMC found (nothing has boot0 beside it)"; exit 1; }
echo "eMMC: $EMMC"

lsblk -o NAME,SIZE,PARTLABEL "$EMMC" > lsblk.txt
dmesg > dmesg-sd.txt
uname -a > uname.txt
cat /proc/cpuinfo > cpuinfo.txt
cat /proc/meminfo > meminfo.txt
cp /sys/firmware/fdt board-runtime-sd.dtb
for d in /sys/bus/sdio/devices/*; do
	[ -e "$d/vendor" ] && echo "${d##*/} $(cat "$d/vendor") $(cat "$d/device")"
done > sdio.txt

dd if="$EMMC" of=factory_idbloader.bin bs=512 skip=64 count=4096 2>/dev/null

if command -v python3 >/dev/null; then
	python3 - "$EMMC" <<'EOF' | tee dtbs.txt
import hashlib, struct, subprocess, sys
parts = subprocess.run(['lsblk', '-lnpo', 'NAME,PARTLABEL', sys.argv[1]], capture_output=True, text=True).stdout
seen = set()
for line in parts.splitlines():
	f = line.split()
	if len(f) < 2 or not f[1].startswith(('boot', 'vendor_boot', 'resource', 'dtbo')):
		continue
	data = open(f[0], 'rb').read()
	i = data.find(b'\xd0\x0d\xfe\xed')
	while i >= 0:
		n = struct.unpack('>I', data[i+4:i+8])[0]
		blob = data[i:i+n]
		h = hashlib.md5(blob).hexdigest()
		if 50000 < n < 1000000 and h not in seen:
			seen.add(h)
			name = f'dtb-{f[1]}-{i:#x}.dtb'
			open(name, 'wb').write(blob)
			print(name, n)
		i = data.find(b'\xd0\x0d\xfe\xed', i + 4)
EOF
fi

# no python, or nothing found: keep the raw boot partition and carve it on the host
if ! ls dtb-*.dtb >/dev/null 2>&1; then
	BOOT=$(lsblk -lnpo NAME,PARTLABEL "$EMMC" | awk '$2 ~ /^boot(_a)?$/ {print $1; exit}')
	[ -n "$BOOT" ] && dd if="$BOOT" of=boot-partition.img bs=4M 2>/dev/null && echo "raw $BOOT kept"
fi

sync
echo "done:"; ls -la "$OUT"
