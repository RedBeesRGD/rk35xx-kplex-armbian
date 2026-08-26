#!/bin/bash
# Interleaved A/B: stock, fix, stock, fix ... one rep each, alternating.
# Stimulus: 2.4 GHz pinned, stress-ng with Wi-Fi idle, verdict after load stops.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PAIRS=${PAIRS:-10}
QUIET=${QUIET:-45}
FIXIMG=${FIXIMG:-/tmp/iram-zero.bin}
FIXNAME=${FIXNAME:-zero}
LOG=/tmp/interleave.csv
[ -s "$LOG" ] || echo "pair,arm,rate,mbps,verdict" > "$LOG"

rep(){ # arm, image-or-restore
  /tmp/fw-install.sh "$2" >/dev/null 2>&1
  wpa_cli -i wlan0 set_network 0 freq_list 2462 >/dev/null 2>&1
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 25); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 4
  # the latch needs more than a fresh boot: rep 1 after a reload never latches,
  # reps 2+ do. Burn one association so the stimulus runs on a later one.
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 25); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 4
  stress-ng --cpu "$(nproc)" --timeout "$QUIET" >/dev/null 2>&1
  sleep 8
  R=$(iw dev wlan0 link | awk '/tx bitrate/{print $3; exit}')
  M=$(iperf3 -c 192.168.1.211 --bind-dev wlan0 -t 6 -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1)
  M=${M:-0}
  V=ok; awk -v r="${R:-0}" -v m="$M" 'BEGIN{exit !(r+0 < 40 && m+0 < 40)}' && V=LATCHED
  echo "$3,$1,$R,$M,$V" | tee -a "$LOG"
}
for p in $(seq 1 "$PAIRS"); do
  rep stock  restore  "$p"
  rep "$FIXNAME" "$FIXIMG" "$p"
done
wpa_cli -i wlan0 set_network 0 freq_list "" >/dev/null 2>&1
/tmp/fw-install.sh restore >/dev/null 2>&1
