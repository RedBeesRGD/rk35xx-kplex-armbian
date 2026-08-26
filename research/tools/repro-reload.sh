#!/bin/bash
# Reproduce the TX collapse via firmware cold-start (module reload), which is the
# condition the observed latch appeared under. Alternates CPU load per trial.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TRIALS=${1:-20}
PEER=${PEER:-192.168.1.211}
BAD_MBPS=${BAD_MBPS:-40}
PROBE=${PROBE:-4}
LOG=${LOG:-/tmp/repro-reload.csv}
P=/proc/skwifid/chip1.sdio/wlan0

[ -s "$LOG" ] || echo "trial,ts,arm,freq,width,rssi,tx_rate_report,fw_tx,fw_psr,fw_txfail,mbps,wlan0_MB,end0_MB,verdict" > "$LOG"
txb(){ cat /sys/class/net/$1/statistics/tx_bytes; }

for i in $(seq 1 "$TRIALS"); do
  ARM=noload; [ $((i % 2)) -eq 0 ] && ARM=load
  [ "$ARM" = load ] && { stress-ng --cpu 4 --timeout 45 >/dev/null 2>&1 & LP=$!; } || LP=""

  systemctl stop netplan-wpa-wlan0 >/dev/null 2>&1
  rmmod swt6621s_wifi 2>/dev/null; rmmod skwbt 2>/dev/null; rmmod skw_sdio_lite 2>/dev/null
  sleep 2
  modprobe skw_sdio_lite; sleep 1; modprobe swt6621s_wifi
  for _ in $(seq 1 20); do sleep 1; [ -d /sys/class/net/wlan0 ] && break; done
  systemctl start netplan-wpa-wlan0 >/dev/null 2>&1
  for _ in $(seq 1 40); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  for _ in $(seq 1 20); do sleep 1; ip -4 addr show wlan0 | grep -q "inet " && break; done
  sleep 3

  FREQ=$(iw dev wlan0 link | awk '/freq:/{print $2}')
  RSSI=$(iw dev wlan0 link | awk '/signal:/{print $2}')
  WIDTH=$(awk '/connect width/{print $3}' $P 2>/dev/null)
  w0=$(txb wlan0); e0=$(txb end0)
  OUT=$(iperf3 -c "$PEER" --bind-dev wlan0 -t $PROBE -f m 2>&1 | grep sender | tail -1)
  w1=$(txb wlan0); e1=$(txb end0)
  MBPS=$(echo "$OUT" | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1); [ -z "$MBPS" ] && MBPS=0
  TXR=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')
  F=$(grep -E "^ +TX:" $P 2>/dev/null)
  MODE=$(echo "$F" | grep -oE 'legacy_rate: [0-9]+|mcs: [0-9]+' | tr ' ' '=' | head -1)
  PSR=$(echo "$F" | grep -oE 'psr: [0-9]+' | cut -d' ' -f2)
  TXF=$(echo "$F" | grep -oE 'tx_failed: [0-9]+' | cut -d' ' -f2)
  # true latch signature: firmware reports a LEGACY rate *and* throughput collapsed
  V=ok
  case "$MODE" in
    legacy_rate*) awk -v m="$MBPS" -v b="$BAD_MBPS" 'BEGIN{exit !(m+0 < b+0)}' && V=BAD ;;
  esac

  echo "$i,$(date +%H:%M:%S),$ARM,$FREQ,$WIDTH,$RSSI,$TXR,$MODE,$PSR,$TXF,$MBPS,$(( (w1-w0)/1000000 )),$(( (e1-e0)/1000000 )),$V" | tee -a "$LOG"
  [ -n "$LP" ] && { kill $LP 2>/dev/null; wait $LP 2>/dev/null; }
  [ "$V" = BAD ] && [ "${FOREVER:-0}" != 1 ] && { echo "REPRODUCED trial $i arm=$ARM" | tee -a "$LOG"; exit 0; }
done
echo "no reproduction in $TRIALS trials" | tee -a "$LOG"; exit 1
