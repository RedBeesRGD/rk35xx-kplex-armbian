#!/bin/bash
# Reproduce the TX rate latch with MMC IO, not CPU load.
# WiFi is SDIO on mmc1 (ffc20000.mmc); rootfs is mmc0 (ffc30000.mmc). Hammering
# MMC starves the SDIO path, so the firmware sees too few TX attempts per interval,
# every up-probe scores as lost, and the unclamped backoff runs away.
# Load is removed before the verdict measurement -- a latch must persist without it.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/proc/skwifid/chip1.sdio/wlan0
PEER=${PEER:-192.168.1.211}
REPS=${REPS:-1}
LOAD=${LOAD:-70}
JOBS=${JOBS:-4}
DEV=${DEV:-/dev/mmcblk0}
LABEL=${1:-run}
LOG=${LOG:-/tmp/mmcio-repro.csv}
[ -s "$LOG" ] || echo "label,rep,freq,rssi,during_mbps,after_mbps,iw_rate,fw,verdict" > "$LOG"

m(){ iperf3 -c "$PEER" --bind-dev wlan0 -t "$1" -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1; }

for r in $(seq 1 "$REPS"); do
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 30); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 5

  for j in $(seq 1 "$JOBS"); do
    ( end=$((SECONDS+LOAD)); while [ $SECONDS -lt $end ]; do
        dd if="$DEV" of=/dev/null bs=1M count=256 iflag=direct >/dev/null 2>&1; done ) &
  done
  sleep 3
  DURING=$(m $((LOAD-10))); DURING=${DURING:-0}
  wait
  sleep 12
  AFTER=$(m 8); AFTER=${AFTER:-0}

  FREQ=$(iw dev wlan0 link | awk '/freq:/{print $2}')
  RSSI=$(iw dev wlan0 link | awk '/signal:/{print $2}')
  RATE=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')
  FW=$(grep -E '^ +TX:' $P | grep -oE 'legacy_rate: [0-9]+|mcs: [0-9]+' | head -1)
  V=ok; case "$FW" in legacy*) awk -v a="$AFTER" 'BEGIN{exit !(a+0 < 40)}' && V=LATCHED;; esac
  echo "$LABEL,$r,$FREQ,$RSSI,$DURING,$AFTER,$RATE,$FW,$V" | tee -a "$LOG"
done
