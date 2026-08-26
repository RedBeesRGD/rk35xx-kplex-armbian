#!/bin/bash
# Test the runtime firmware patch against a LIVE latch, with roam/association
# contamination detected explicitly.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
P=/proc/skwifid/chip1.sdio/wlan0
ADDR=0x0012c800; ORIG=0xd0cc4288; PATCHED=0xe0144288

assoc_n(){ journalctl -u netplan-wpa-wlan0 --since "-2 hour" --no-pager 2>/dev/null | grep -c "CTRL-EVENT-CONNECTED"; }
ctx(){ echo "bssid=$(wpa_cli -i wlan0 status 2>/dev/null | awk -F= '/^bssid/{print $2}') freq=$(wpa_cli -i wlan0 status 2>/dev/null | awk -F= '/^freq/{print $2}') assoc_events=$(assoc_n)"; }
m(){ iperf3 -c 192.168.1.211 --bind-dev wlan0 -t "$1" -f m 2>&1 | grep sender | grep -oE '[0-9.]+ Mbits/sec' | tail -1; }
fw(){ grep -E '^ +TX:' $P | tr -s ' '; }

A0=$(assoc_n)
echo "== BEFORE PATCH =="; ctx; echo "   BE: $(m 6)"; echo "   fw:$(fw)"
echo "== WRITE $ADDR = $PATCHED =="
python3 /tmp/skwmem.py wr $ADDR $PATCHED
sleep 2
echo "== AFTER PATCH =="; echo "   BE: $(m 10)"; echo "   fw:$(fw)"; echo "   BE: $(m 6)"; echo "   fw:$(fw)"; ctx
A1=$(assoc_n)
echo "== association events during test: $((A1-A0))  (must be 0 for a valid result) =="
