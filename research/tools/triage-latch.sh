#!/bin/bash
# Run on a LIVE latched link. Discriminates between competing mechanisms.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PEER=${PEER:-192.168.1.211}
T=${T:-4}
P=/proc/skwifid/chip1.sdio/wlan0

fw()  { grep -E "^ +TX:|^ +RX:|tidmap" $P | tr -s ' ' | paste -sd' | ' - ; }
run() { # label, extra iperf args
  local lbl="$1"; shift
  local w0=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
  local o=$(iperf3 -c "$PEER" --bind-dev wlan0 -t $T -f m "$@" 2>&1 | grep -E "sender|receiver" | tail -1)
  local w1=$(cat /sys/class/net/wlan0/statistics/tx_bytes)
  local m=$(echo "$o" | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1)
  printf "%-26s %8s Mbps  wlan0=%sMB  | %s\n" "$lbl" "${m:-FAIL}" "$(( (w1-w0)/1000000 ))" "$(fw)"
}

echo "### link"; iw dev wlan0 link | grep -E "freq|signal|bitrate"
echo "### 1. access-category sweep (different TIDs -> different BA sessions)"
run "BE (TID 0, default)"
run "BK (TID 1) tos 0x20"  --tos 0x20
run "VI (TID 5) tos 0xa0"  --tos 0xa0
run "VO (TID 7) tos 0xe0"  --tos 0xe0

echo "### 2. UDP offered 100M (bypasses TCP backoff)"
run "UDP 100M" -u -b 100M

echo "### 3. small vs large payload (aggregation sensitivity)"
run "TCP MSS 500" -M 500

echo "### 4. rate-floor sweep, psr readback"
for c in 0x30 0x32 0x34 0x37 0xc0 0xc2; do
  python3 /tmp/skw_ratectl.py rebuild $c >/dev/null 2>&1
  sleep 1
  run "minrate $c"
done
python3 /tmp/skw_ratectl.py rebuild 0x30 >/dev/null 2>&1
echo "### restored minrate 0x30"
