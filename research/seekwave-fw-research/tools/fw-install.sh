#!/bin/bash
# Install an IRAM image and cold-start the chip. Usage: fw-install.sh <image|restore>
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NAME="SWT6621S_IRAM_SDIO.h96max-zx,rk3518-tvbox.bin"
SRC="$1"
if [ "$SRC" = restore ]; then SRC="/root/fw-backup/$NAME"; rm -f /root/fw-patch-active
else touch /root/fw-patch-active; fi
for d in /lib/firmware /lib/firmware/seekwave; do
  [ -d "$d" ] && cp -f "$SRC" "$d/$NAME"
done
md5sum "$SRC" "/lib/firmware/$NAME" | awk '{print "  " $0}'
systemctl stop netplan-wpa-wlan0 >/dev/null 2>&1
rmmod swt6621s_wifi 2>/dev/null; rmmod skwbt 2>/dev/null; rmmod skw_sdio_lite 2>/dev/null
sleep 2
modprobe skw_sdio_lite; sleep 1; modprobe swt6621s_wifi
for _ in $(seq 1 20); do sleep 1; [ -d /sys/class/net/wlan0 ] && break; done
systemctl start netplan-wpa-wlan0 >/dev/null 2>&1
for _ in $(seq 1 40); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
sleep 4
iw dev wlan0 link | grep -E "freq|signal|bitrate"
