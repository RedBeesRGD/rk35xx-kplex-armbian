#!/bin/sh
# SWT6621S TX rate latch fix. UNCONFIRMED -- see README before deploying.
# Patches file offset 0x2d68a: 11 e0 (b 0x12d6b0) -> ff e7 (b 0x12d68c), so a
# rate-control rebuild refreshes the link capability map instead of branching
# past the ROM call that populates it. Without this a rebuild re-derives the
# rate ladder from a map it never refreshes, collapsing it to one 6 Mbit/s entry.
# Images are identified by SHA-256; anything else is refused.
# Usage: seekwave-fw-patch.sh [--check|--revert]

set -u

STOCK=c6f9698c2c3bd421c6aff55672ff05a51224889898741b7f81cd61d5fd3728d4
PATCHED=63d4fcfc1475151d14c5a4d036c4edbc390e32476263dd372ab72b19e8ad9751
STOCK_BYTES='\021\340'
PATCHED_BYTES='\377\347'
OFFSET=$((0x2d68a))

mode=apply
case "${1:-}" in
    --check)  mode=check ;;
    --revert) mode=revert ;;
    "")       ;;
    *)        echo "usage: $0 [--check|--revert]" >&2; exit 2 ;;
esac

# systemd reads a <N> stderr prefix as syslog priority; <3> renders red.
if [ -n "${INVOCATION_ID:-}" ]; then EP='<3>'; IP='<6>'; else EP=''; IP=''; fi
err() { printf '%s%s\n' "$EP" "$*" >&2; }
log() { printf '%s%s\n' "$IP" "$*" >&2; }

sha()  { sha256sum "$1" | cut -d' ' -f1; }
poke() { printf "$2" | dd of="$1" bs=1 seek="$OFFSET" conv=notrunc status=none; }

write() { # path, bytes, want_sha, verb
    poke "$1" "$2"
    if [ "$(sha "$1")" = "$3" ]; then log "$1 $4"; changed=1; else err "$1 write failed"; rc=1; fi
}

rc=0
changed=0
seen=''

for f in /lib/firmware/SWT6621S_IRAM_SDIO*.bin /lib/firmware/seekwave/SWT6621S_IRAM_SDIO*.bin; do
    [ -f "$f" ] || continue
    path=$(readlink -f "$f")
    case " $seen " in *" $path "*) continue ;; esac
    seen="$seen $path"

    digest=$(sha "$path")
    case "$digest" in
        "$STOCK")   state=stock ;;
        "$PATCHED") state=patched ;;
        *) err "$path sha256 $digest is neither $STOCK nor $PATCHED; refusing"; rc=1; continue ;;
    esac

    case "$mode:$state" in
        apply:stock)    write "$path" "$PATCHED_BYTES" "$PATCHED" patched ;;
        revert:patched) write "$path" "$STOCK_BYTES"   "$STOCK"   reverted ;;
        *)              log "$path $state" ;;
    esac
done

[ -n "$seen" ] || { err "no SWT6621S_IRAM_SDIO*.bin found"; exit 1; }
[ "$changed" = 1 ] && [ -d /sys/module/swt6621s_wifi ] && log "reload swt6621s_wifi or reboot to apply"

exit "$rc"
