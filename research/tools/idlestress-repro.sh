#!/bin/bash
# Reproduce the TX rate latch: WiFi IDLE while the CPU is loaded, then measure.
# No traffic during the window is the point -- the firmware gets no TX attempts,
# so no up-probe can reach cfg[0x25] attempts, every probe scores as lost, and the
# unclamped backoff at ctx+0x1a9 runs away. Load is removed before the verdict.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/proc/skwifid/chip1.sdio/wlan0
PEER=${PEER:-192.168.1.211}
REPS=${REPS:-3}
QUIET=${QUIET:-60}
CPUS=${CPUS:-$(nproc)}
STRESS=${STRESS:-1}
LABEL=${1:-run}
LOG=${LOG:-/tmp/idlestress.csv}
[ -s "$LOG" ] || echo "label,rep,stress,freq,rssi,after_mbps,iw_rate,fw,verdict" > "$LOG"

m(){ iperf3 -c "$PEER" --bind-dev wlan0 -t "$1" -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1; }

for r in $(seq 1 "$REPS"); do
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 30); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 5
  if [ "$STRESS" = 1 ]; then stress-ng --cpu "$CPUS" --timeout "$QUIET" >/dev/null 2>&1; else sleep "$QUIET"; fi
  sleep 8
  AFTER=$(m 8); AFTER=${AFTER:-0}
  FREQ=$(iw dev wlan0 link | awk '/freq:/{print $2}')
  RSSI=$(iw dev wlan0 link | awk '/signal:/{print $2}')
  RATE=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')
  FW=$(grep -E '^ +TX:' $P | grep -oE 'legacy_rate: [0-9]+|mcs: [0-9]+' | head -1)
  V=ok; case "$FW" in legacy*) awk -v a="$AFTER" 'BEGIN{exit !(a+0 < 40)}' && V=LATCHED;; esac
  echo "$LABEL,$r,$STRESS,$FREQ,$RSSI,$AFTER,$RATE,$FW,$V" | tee -a "$LOG"
done
