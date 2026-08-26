#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
m(){ iperf3 -c 192.168.1.211 --bind-dev wlan0 -t 6 -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1; }
st(){ iw dev wlan0 link >/dev/null 2>&1; echo "   $(iw dev wlan0 link | awk '/tx bitrate/{print "iw="$3}')  $(grep -E '^ +TX:' /proc/skwifid/chip1.sdio/wlan0 | tr -s ' ')"; }
{
wpa_cli -i wlan0 set_network 0 freq_list 2462 >/dev/null 2>&1
for i in 1 2 3 4; do
  wpa_cli -i wlan0 reassociate >/dev/null 2>&1
  for _ in $(seq 1 25); do sleep 1; iw dev wlan0 link 2>/dev/null | grep -q "^Connected" && break; done
  sleep 4
  stress-ng --cpu "$(nproc)" --timeout 60 >/dev/null 2>&1
  sleep 8
  MB=$(m)
  echo "attempt $i: $MB"; st
  case "$MB" in ''|*' Mbits/sec') ;; esac
  V=$(echo "$MB" | cut -d' ' -f1)
  if awk -v v="${V:-0}" 'BEGIN{exit !(v+0 < 40)}'; then echo "### LATCHED, running watchdog"; break; fi
done
echo "### watchdog run"
/tmp/seekwave-latch-watchdog.sh wlan0; echo "   exit=$?"
sleep 12
echo "### after watchdog"; echo "   $(m)"; st
wpa_cli -i wlan0 set_network 0 freq_list "" >/dev/null 2>&1
} > /tmp/wdtest.out 2>&1
