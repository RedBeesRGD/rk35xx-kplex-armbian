#!/bin/bash
# Measure box->peer throughput, FORCED over wlan0, with interface counters as proof.
# Usage: wlan-measure.sh [seconds] [peer]
set -u
SECS=${1:-5}
PEER=${2:-192.168.1.211}
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

r()  { cat /sys/class/net/$1/statistics/tx_bytes; }
w0=$(r wlan0); e0=$(r end0)
LINK_BEFORE=$(iw dev wlan0 link | grep -E "signal:|tx bitrate|rx bitrate" | tr -s ' ' | paste -sd'|' -)

OUT=$(sudo -n iperf3 -c "$PEER" --bind-dev wlan0 -t "$SECS" -f m 2>&1 | grep -E "sender|error|refused" | tail -2)

w1=$(r wlan0); e1=$(r end0)
LINK_AFTER=$(iw dev wlan0 link | grep -E "signal:|tx bitrate|rx bitrate" | tr -s ' ' | paste -sd'|' -)

MBPS=$(echo "$OUT" | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1)
echo "wlan0_tx_MB=$(( (w1-w0)/1000000 ))  end0_tx_MB=$(( (e1-e0)/1000000 ))  throughput_Mbps=${MBPS:-FAIL}"
echo "before: $LINK_BEFORE"
echo "after : $LINK_AFTER"
[ -n "${VERBOSE:-}" ] && echo "$OUT"
exit 0
