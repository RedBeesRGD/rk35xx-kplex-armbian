#!/bin/bash
# Time to recover from the latch under sustained load.
# Rate is read from `iw dev wlan0 link`, which forces the driver to refresh its
# peer record; reading /proc directly returns a stale one.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PEER=${PEER:-192.168.1.211}
REPS=${REPS:-3}; QUIET=${QUIET:-60}; WATCH=${WATCH:-150}
LABEL=${1:-run}
rate(){ iw dev wlan0 link | awk '/tx bitrate/{print $3; exit}'; }
hi(){ awk -v r="$1" 'BEGIN{exit !(r+0 > 40)}'; }
for r in $(seq 1 "$REPS"); do
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 30); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 5
  stress-ng --cpu "$(nproc)" --timeout "$QUIET" >/dev/null 2>&1
  sleep 8
  PRE=$(rate)
  iperf3 -c "$PEER" --bind-dev wlan0 -t "$WATCH" -f m > /tmp/rec.txt 2>&1 &
  IP=$!; REC=""; TRACE=""
  for i in $(seq 1 $((WATCH/10))); do
    sleep 10
    R=$(rate); TRACE="$TRACE $R"
    [ -z "$REC" ] && hi "$R" && REC=$((i*10))
  done
  wait $IP
  echo "$LABEL rep$r: pre=$PRE recovered_at=${REC:-NEVER}s total=$(grep sender /tmp/rec.txt | grep -oE '[0-9.]+ Mbits/sec' | tail -1) trace:$TRACE"
done
