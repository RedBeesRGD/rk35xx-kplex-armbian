#!/bin/bash
# Hypothesis: probes fail for lack of attempts at low offered load, the unclamped
# backoff accumulates and wraps negative, and the rate can then never climb.
# So: associate, hold the link idle/trickle, THEN apply load.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/proc/skwifid/chip1.sdio/wlan0
PEER=192.168.1.211
LOG=/tmp/idle-repro.csv
[ -s "$LOG" ] || echo "idle_s,mode,freq,rssi,iw_rate,mbps,verdict" > "$LOG"

m(){ local t="$1"; shift; iperf3 -c "$PEER" --bind-dev wlan0 -t "$t" -f m "$@" 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1; }
reassoc(){ wpa_cli -i wlan0 reassociate >/dev/null 2>&1
           for _ in $(seq 1 30); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
           sleep 4; }

for IDLE in "$@"; do
  for MODE in idle trickle; do
    reassoc
    if [ "$MODE" = trickle ]; then ping -i 1 -q "$PEER" >/dev/null 2>&1 & TP=$!; else TP=""; fi
    sleep "$IDLE"
    [ -n "$TP" ] && { kill $TP 2>/dev/null; wait $TP 2>/dev/null; }
    MB=$(m 6); MB=${MB:-0}
    R=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')
    F=$(iw dev wlan0 link | awk '/freq:/{print $2}')
    S=$(iw dev wlan0 link | awk '/signal:/{print $2}')
    FW=$(grep -E '^ +TX:' $P | grep -oE 'legacy_rate: [0-9]+|mcs: [0-9]+' | head -1)
    V=ok; case "$FW" in legacy*) awk -v m="$MB" 'BEGIN{exit !(m+0 < 40)}' && V=LATCHED;; esac
    echo "$IDLE,$MODE,$F,$S,$R,$MB,$V | fw=$FW" | tee -a "$LOG"
  done
done
