#!/bin/sh
# Detect the SWT6621S TX rate latch and clear it by re-associating.
# Latched: firmware reports a legacy TX rate at or below 6 Mbit/s while the
# signal is strong. Confirmed over two samples, because a single sample on an
# idle link reports the last frame sent.
# Usage: seekwave-latch-watchdog.sh [iface]

set -u

IFACE=${1:-wlan0}
PROC=/proc/skwifid/chip1.sdio/$IFACE
MAX_LEGACY_RATE=60      # tenths of Mbit/s
MIN_RSSI=-70
SETTLE=10
COOLDOWN=300            # re-association costs 0.2-3.5 s of link; do not loop on it
STAMP=/run/seekwave-latch-watchdog.$IFACE

if [ -n "${INVOCATION_ID:-}" ]; then WP='<4>'; IP='<6>'; else WP=''; IP=''; fi
warn() { printf '%s%s\n' "$WP" "$*" >&2; }
log()  { printf '%s%s\n' "$IP" "$*" >&2; }

# iw refreshes the driver's cached peer record; reading PROC alone returns a stale one.
sample() {
    iw dev "$IFACE" link >/dev/null 2>&1 || return 1
    [ -r "$PROC" ] || return 1
    awk '
        /^ +TX:/ { for (i = 1; i <= NF; i++) {
                       if ($i == "legacy_rate:") rate = $(i+1)
                       if ($i == "mcs:")         mcs  = 1 } }
        /rssi:/  { for (i = 1; i <= NF; i++) if ($i == "rssi:") { r = $(i+1); sub(/,$/, "", r) } }
        END      { print (mcs ? "mcs" : "legacy"), rate + 0, r + 0 }
    ' "$PROC"
}

latched() {
    set -- $(sample) || return 1
    [ "${1:-}" = legacy ] || return 1
    # rate 0 means the driver has no populated record; not a latch
    [ "${2:-0}" -gt 0 ] || return 1
    [ "${2:-0}" -le "$MAX_LEGACY_RATE" ] || return 1
    [ "${3:-0}" -gt "$MIN_RSSI" ] || return 1
    return 0
}

iw dev "$IFACE" link 2>/dev/null | grep -q '^Connected' || exit 0

latched || exit 0

# uptime, not wall clock, so an NTP step cannot extend or skip the cooldown.
# If it is unreadable, act rather than block.
now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$now" in *[!0-9]*|'') now='' ;; esac

if [ -n "$now" ] && [ -r "$STAMP" ]; then
    last=$(cat "$STAMP" 2>/dev/null)
    case "$last" in *[!0-9]*|'') last=0 ;; esac
    [ "$now" -ge "$last" ] || last=0        # uptime went backwards: rebooted
    if [ $((now - last)) -lt "$COOLDOWN" ]; then
        log "$IFACE still latched, $((COOLDOWN - now + last))s of cooldown left"
        exit 0
    fi
fi

sleep "$SETTLE"
latched || { log "$IFACE transient low rate, not acting"; exit 0; }

warn "$IFACE latched at a legacy rate with a strong signal; re-associating"
[ -n "$now" ] && echo "$now" > "$STAMP"
wpa_cli -i "$IFACE" reassociate >/dev/null 2>&1 || {
    warn "$IFACE reassociate failed"
    exit 1
}
exit 0
