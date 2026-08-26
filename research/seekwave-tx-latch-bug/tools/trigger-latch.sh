#!/bin/bash
# Deterministic trigger attempt: drive TX failures on TID 0 (BE) only, then release
# the rate floor and see whether BE stays pinned while VI stays healthy.
# Usage: trigger-latch.sh [reps] [failrate_code]
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPS=${1:-5}
FAILCODE=${2:-0x37}
PEER=${PEER:-192.168.1.211}
P=/proc/skwifid/chip1.sdio/wlan0
LOG=/tmp/trigger-latch.csv
[ -s "$LOG" ] || echo "rep,healthy_be,after_be,after_vi,after_rate,verdict" > "$LOG"

m(){ iperf3 -c "$PEER" --bind-dev wlan0 -t "$1" -f m ${2:-} 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1; }
rate(){ iw dev wlan0 link | awk '/tx bitrate/{print $3}'; }
reassoc(){ wpa_cli -i wlan0 reassociate >/dev/null 2>&1
           for _ in $(seq 1 30); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
           sleep 4; }

for r in $(seq 1 "$REPS"); do
  reassoc
  python3 /tmp/skw_ratectl.py rebuild 0x30 >/dev/null 2>&1
  H=$(m 4); H=${H:-0}
  # --- induce failures on BE only ---
  python3 /tmp/skw_ratectl.py rebuild "$FAILCODE" >/dev/null 2>&1
  m 12 >/dev/null
  python3 /tmp/skw_ratectl.py rebuild 0x30 >/dev/null 2>&1
  sleep 2
  # --- did BE stay pinned? ---
  A=$(m 5);  A=${A:-0}
  R=$(rate)
  V=$(m 5 --tos 0xa0); V=${V:-0}
  VER=no-latch
  awk -v a="$A" -v h="$H" 'BEGIN{exit !(a+0 < 15 && h+0 > 40)}' && VER=LATCHED
  echo "$r,$H,$A,$V,$R,$VER" | tee -a "$LOG"
done
