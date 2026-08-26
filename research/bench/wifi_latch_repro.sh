#!/bin/sh
# Reproduce the SWT6621S uplink rate latch: uplink pins at 6.0 MBit/s and never
# recovers without re-association. Established 2026-08-23, latches at ~+75 s.
#
# Three conditions all matter; drop any one and it will not reproduce:
#
#   2.4 GHz          every latch on record is 20 MHz / 2.4 GHz. A harsher stimulus
#                    on 5 GHz (--cpu 8 --io 4 --vm 2 plus a flood ping, 240 s) never
#                    left 600.4 MBit/s.
#   continuous load  not 60 s bursts. 60 burst-cycles produced 0 latches because the
#                    throughput probe between them re-trains the rate ladder.
#   sparse traffic   ~2-3 pkt/s, not silence and not saturation. Windows carrying
#                    8-17 packets never latched -- nothing is sent, so nothing degrades.
#
# Reads /proc and dmesg only during the window; a bulk probe here would mask the
# fault. Throughput is confirmed once at the end, and it is the only number to
# trust: tx_bytes counts frames the driver discarded and has read 78x high.
#
# Usage: ./wifi_latch_repro.sh [gateway]     (run detached; ssh traffic suppresses it)
set -u
OUT=/home/art/repro.log
GW="${1:-192.168.1.1}"
CH24="2412 2417 2422 2427 2432 2437 2442 2447 2452 2457 2462"
SKW=/home/art/skw
LOAD=300
: > "$OUT"
log() { echo "$*" >> "$OUT"; }

sudo -n python3 "$SKW/wpactl.py" SET_NETWORK 0 freq_list $CH24 >/dev/null 2>&1
sudo -n python3 "$SKW/wpactl.py" REASSOCIATE >/dev/null 2>&1
for _ in $(seq 1 40); do sleep 2; ip -4 addr show wlan0 | grep -q 'inet ' && break; done
sleep 8

rate() { /usr/sbin/iw dev wlan0 station dump >/dev/null 2>&1; /usr/sbin/iw dev wlan0 link | sed -n 's/.*tx bitrate: //p'; }
tidmap() { sed -n 's/.*TX: tidmap: \([^,]*\),.*/\1/p' /proc/skwifid/chip1.sdio/wlan0 | head -1; }
TXP=/sys/class/net/wlan0/statistics/tx_packets

log "module   $(md5sum /lib/modules/$(uname -r)/updates/dkms/swt6621s_wifi.ko | cut -c1-12)"
log "freq     $(/usr/sbin/iw dev wlan0 link | sed -n 's/.*freq: //p')"
log "baseline $(python3 "$SKW/txprobe.py" 4 "$GW") Mbps   [$(rate)]"
log ""

P0=$(cat "$TXP")
stress-ng --cpu 4 --timeout "$LOAD" >/dev/null 2>&1 &
SP=$!
t=0
while kill -0 "$SP" 2>/dev/null; do
  sleep 15; t=$((t + 15))
  sudo -n ping -c 2 -W 2 "$GW" >/dev/null 2>&1        # the sparse traffic the fault needs
  log "load+${t}s  tidmap=$(tidmap)  $(rate)"
done
log ""
log "--- load off, tx_packets during window: $(($(cat "$TXP") - P0)) ---"
for t in 15 30 45 60; do
  sleep 15
  log "post+${t}s  tidmap=$(tidmap)  $(rate)"
done

log ""
log "throughput confirmation (first bulk TX of the run):"
log "   $(python3 "$SKW/txprobe.py" 4 "$GW") Mbps   [$(rate)]   tidmap=$(tidmap)"
log "DONE"
