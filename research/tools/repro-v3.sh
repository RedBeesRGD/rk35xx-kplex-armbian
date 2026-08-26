#!/bin/bash
# Reproduce the TX-rate collapse on demand.
# Each trial: reassociate -> wait for link -> forced-wlan0 throughput probe -> classify.
# Logs one CSV line per trial; stops (unless FOREVER=1) on the first bad trial.
#
# bad := throughput below BAD_MBPS while rssi is strong (so it is not range)
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BGFLOW=${BGFLOW:-1}
TRIALS=${1:-40}
PEER=${PEER:-192.168.1.211}
BAD_MBPS=${BAD_MBPS:-40}
PROBE=${PROBE:-4}
LOG=${LOG:-/tmp/repro-v3.csv}
LOAD=${LOAD:-0}          # 1 = run stress-ng across the association window

[ -s "$LOG" ] || echo "trial,ts,freq,width,rssi,tx_rate_report,fw_tx_mode,fw_psr,fw_txfail,mbps,wlan0_MB,end0_MB,verdict" > "$LOG"

txb() { cat /sys/class/net/$1/statistics/tx_bytes; }

for i in $(seq 1 "$TRIALS"); do
  if [ "$LOAD" = 1 ] && command -v stress-ng >/dev/null; then
    stress-ng --cpu 4 --timeout 20 >/dev/null 2>&1 &
    LOADPID=$!
  else
    LOADPID=""
  fi

  if [ "$BGFLOW" = 1 ]; then
    ping -i 0.05 -q 192.168.1.211 >/dev/null 2>&1 &
    PINGPID=$!
  else
    PINGPID=""
  fi
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 30); do
    sleep 1
    iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break
  done
  sleep 3

  [ -n "$PINGPID" ] && { kill $PINGPID 2>/dev/null; wait $PINGPID 2>/dev/null; }
  FREQ=$(iw dev wlan0 link | awk '/freq:/{print $2}')
  RSSI=$(iw dev wlan0 link | awk '/signal:/{print $2}')
  WIDTH=$(awk '/connect width/{print $3}' /proc/skwifid/chip1.sdio/wlan0)

  w0=$(txb wlan0); e0=$(txb end0)
  OUT=$(iperf3 -c "$PEER" --bind-dev wlan0 -t "$PROBE" -f m 2>&1 | grep sender | tail -1)
  w1=$(txb wlan0); e1=$(txb end0)
  MBPS=$(echo "$OUT" | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1)
  [ -z "$MBPS" ] && MBPS=0

  TXR=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')
  FWLINE=$(grep -E "^ +TX:" /proc/skwifid/chip1.sdio/wlan0)
  MODE=$(echo "$FWLINE" | grep -oE 'legacy_rate: [0-9]+|mcs: [0-9]+' | tr ' ' '=' | head -1)
  PSR=$(echo "$FWLINE"  | grep -oE 'psr: [0-9]+' | cut -d' ' -f2)
  TXF=$(echo "$FWLINE"  | grep -oE 'tx_failed: [0-9]+' | cut -d' ' -f2)

  # true latch signature: firmware reports a LEGACY rate *and* throughput collapsed
  VERDICT=ok
  case "$MODE" in
    legacy_rate*) awk -v m="$MBPS" -v b="$BAD_MBPS" 'BEGIN{exit !(m+0 < b+0)}' && VERDICT=BAD ;;
  esac

  echo "$i,$(date +%H:%M:%S),$FREQ,$WIDTH,$RSSI,$TXR,$MODE,$PSR,$TXF,$MBPS,$(( (w1-w0)/1000000 )),$(( (e1-e0)/1000000 )),$VERDICT" | tee -a "$LOG"

  [ -n "$LOADPID" ] && wait "$LOADPID" 2>/dev/null
  if [ "$VERDICT" = BAD ] && [ "${FOREVER:-0}" != 1 ]; then
    echo "REPRODUCED on trial $i" | tee -a "$LOG"
    exit 0
  fi
done
echo "no reproduction in $TRIALS trials" | tee -a "$LOG"
exit 1
