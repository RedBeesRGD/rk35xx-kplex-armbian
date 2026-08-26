#!/bin/bash
# Alternating blocks: install one image, then run several reps on it without
# reloading. Latches only appear from the 2nd rep after a firmware boot, so a
# per-rep firmware swap suppresses the very thing being measured.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ROUNDS=${ROUNDS:-3}
REPS=${REPS:-4}
QUIET=${QUIET:-60}
FIXIMG=${FIXIMG:-/tmp/iram-zero.bin}
FIXNAME=${FIXNAME:-zero}
LOG=/tmp/blocks.csv
[ -s "$LOG" ] || echo "round,arm,rep,rate,mbps,verdict" > "$LOG"

block(){ # arm, image
  /tmp/fw-install.sh "$2" >/dev/null 2>&1
  wpa_cli -i wlan0 set_network 0 freq_list 2462 >/dev/null 2>&1
  for r in $(seq 1 "$REPS"); do
    wpa_cli -i wlan0 reassociate >/dev/null 2>&1
    for _ in $(seq 1 25); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
    sleep 4
    stress-ng --cpu "$(nproc)" --timeout "$QUIET" >/dev/null 2>&1
    sleep 8
    R=$(iw dev wlan0 link | awk '/tx bitrate/{print $3; exit}')
    M=$(iperf3 -c 192.168.1.211 --bind-dev wlan0 -t 6 -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1 | cut -d' ' -f1)
    M=${M:-0}
    V=ok; awk -v r="${R:-0}" -v m="$M" 'BEGIN{exit !(r+0 < 40 && m+0 < 40)}' && V=LATCHED
    echo "$3,$1,$r,$R,$M,$V" | tee -a "$LOG"
  done
}
for n in $(seq 1 "$ROUNDS"); do
  block stock      restore   "$n"
  block "$FIXNAME" "$FIXIMG" "$n"
done
wpa_cli -i wlan0 set_network 0 freq_list "" >/dev/null 2>&1
/tmp/fw-install.sh restore >/dev/null 2>&1
