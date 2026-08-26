#!/bin/bash
# Run on a LIVE latch. Tests the probe-backoff prediction: a signed-char counter
# walking away from zero clears after ~255 RC intervals, so recovery should appear
# minutes in -- far past the 150 s already tried. No writes, nothing disruptive.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/proc/skwifid/chip1.sdio/wlan0
an(){ journalctl -u netplan-wpa-wlan0 --since "-3 hour" --no-pager 2>/dev/null | grep -c "CTRL-EVENT-CONNECTED"; }
m(){ local t="$1"; shift; iperf3 -c 192.168.1.211 --bind-dev wlan0 -t "$t" -f m "$@" 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1; }

echo "### confirm latch"; iw dev wlan0 link | grep -E "freq|signal|bitrate"; grep -E "^ +TX:" $P
echo "### per-TID check"
echo "  BE: $(m 4)"; echo "  VI: $(m 4 --tos 0xa0)"; echo "  BE: $(m 4)"
A0=$(an)
echo "### 12-minute continuous BE soak, sampled every 30 s"
iperf3 -c 192.168.1.211 --bind-dev wlan0 -t 720 -f m > /tmp/latchsoak.txt 2>&1 &
IP=$!
for i in $(seq 1 24); do
  sleep 30
  echo "  $((i*30))s  iw=$(iw dev wlan0 link | awk '/tx bitrate/{print $3}')  $(grep -E '^ +TX:' $P | tr -s ' ')"
done
wait $IP
echo "### soak result"; grep sender /tmp/latchsoak.txt
echo "### association events during soak: $(( $(an) - A0 ))  (must be 0)"
