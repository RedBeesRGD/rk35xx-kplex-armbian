#!/bin/bash
# Find what actually starves the WiFi TX path. For each stressor: start it,
# measure WiFi throughput under it, stop. Looking for a collapse to single digits.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PEER=${PEER:-192.168.1.211}
T=12
m(){ iperf3 -c "$PEER" --bind-dev wlan0 -t $T -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1; }
run(){ # label, command...
  local lbl="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  printf "%-34s %-14s load=%s\n" "$lbl" "$(m)" "$(cut -d' ' -f1 /proc/loadavg)"
  kill $pid 2>/dev/null; pkill -x stress-ng 2>/dev/null; pkill -x dd 2>/dev/null
  sleep 3
}
echo "baseline (no load)                 $(m)"
run "cpu 4"            stress-ng --cpu 4  --timeout 20
run "cpu 16"           stress-ng --cpu 16 --timeout 20
run "cpu 16 + vm 4"    stress-ng --cpu 16 --vm 4 --vm-bytes 128M --timeout 20
run "iomix 4"          stress-ng --iomix 4 --timeout 20
run "hdd 2"            stress-ng --hdd 2 --hdd-bytes 64M --temp-path /tmp --timeout 20
run "sock 8"           stress-ng --sock 8 --timeout 20
run "cpu 8 + iomix 2"  stress-ng --cpu 8 --iomix 2 --timeout 20
run "sched/ctxt churn" stress-ng --switch 8 --timeout 20
echo "recovery (no load)                 $(m)"
