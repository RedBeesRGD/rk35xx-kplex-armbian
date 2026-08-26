#!/bin/bash
# A/B the fix against the reproducing stimulus (idle WiFi + CPU stress), with the
# band pinned to 2.4 GHz so AP band-steering cannot confound the comparison.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
A=$(readlink -f "/lib/firmware/SWT6621S_IRAM_SDIO.h96max-zx,rk3518-tvbox.bin")
B=$(readlink -f "/lib/firmware/seekwave/SWT6621S_IRAM_SDIO.kickpi,k3b.bin")
FIX=/tmp/seekwave-fix-tx-rate-latch.py
reload(){ systemctl stop netplan-wpa-wlan0 >/dev/null 2>&1
  rmmod swt6621s_wifi 2>/dev/null; rmmod skwbt 2>/dev/null; rmmod skw_sdio_lite 2>/dev/null; sleep 2
  modprobe skw_sdio_lite; sleep 1; modprobe swt6621s_wifi
  for _ in $(seq 1 20); do sleep 1; [ -d /sys/class/net/wlan0 ] && break; done
  systemctl start netplan-wpa-wlan0 >/dev/null 2>&1
  for _ in $(seq 1 40); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done; sleep 5; }
pin(){ wpa_cli -i wlan0 set_network 0 freq_list 2462 >/dev/null 2>&1; wpa_cli -i wlan0 reassociate >/dev/null 2>&1; sleep 10; }
arm(){
  if [ "$1" = patched ]; then python3 $FIX "$A" >/dev/null; python3 $FIX "$B" >/dev/null
  else python3 $FIX "$A" --revert >/dev/null; python3 $FIX "$B" --revert >/dev/null; fi
  reload; pin
  echo "######## ARM=$1  md5=$(md5sum "$A" | cut -c1-12)  freq=$(iw dev wlan0 link | awk '/freq:/{print $2}')"
  rm -f /tmp/abpin.csv
  LOG=/tmp/abpin.csv REPS=5 QUIET=60 /tmp/idlestress-repro.sh "$1"
  cp /tmp/abpin.csv /tmp/abpin-$1.csv
}
{ arm stock; arm patched
  echo "######## cleanup"
  python3 $FIX "$A" --revert | tail -2; python3 $FIX "$B" --revert | tail -2
  wpa_cli -i wlan0 set_network 0 freq_list "" >/dev/null 2>&1
  reload; md5sum "$A" "$B"; iw dev wlan0 link | grep -E "freq|bitrate"
} > /tmp/abpin.out 2>&1
