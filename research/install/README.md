# Install

Ranked. DSCP marking costs nothing and is the right answer for a link that must stay up;
the watchdog trades a multi-second outage for recovery; the firmware patch is a root-cause fix
that is not yet confirmed.

## First choice: DSCP VI, no service at all

The latch is per-TID and spares VI/VO. Mark latency-sensitive traffic `0xa0` and it never sees the
bug — 58.4 Mbps on VI against 3.53 on BE, same link, same second. Nothing to install, nothing to
interrupt.

## Last resort: watchdog

Detects a legacy TX rate at or below 6 Mbit/s with a strong signal, confirms over two samples 10 s
apart, then re-associates.

**Re-association drops the link**: 0.2-0.3 s when it lands back on 5 GHz, 3.1-3.5 s when it lands
on 2.4 GHz. That is worse than degraded throughput for anything real-time, so install this only for
traffic that tolerates a multi-second gap and where DSCP marking is not an option. A 300 s cooldown
prevents a recurring latch from becoming a reassociation loop.

```sh
install -m 755 ../seekwave-latch-watchdog.sh /usr/local/sbin/
install -m 644 seekwave-latch-watchdog.service seekwave-latch-watchdog.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now seekwave-latch-watchdog.timer
journalctl -u seekwave-latch-watchdog -f
```

## Firmware patch — root cause, unconfirmed

`../seekwave-fw-patch.sh` patches two bytes at `0x2d68a` so a rate-control rebuild
refreshes the link's capability map instead of branching past the ROM call that
populates it. Without it a rebuild re-derives the rate ladder from a map it never
refreshes, collapsing it to a single 6 Mbit/s entry.

**Unconfirmed.** 0 latches in 14 reps, but no A/B has yet had its stock control
latching in the same window, so the comparison is not proven. Earlier patches at
the two probe-suppression sites were measured and do **not** work.

```sh
install -m 755 ../seekwave-fw-patch.sh /usr/local/sbin/
install -m 644 81-seekwave-fw-patch.rules /etc/udev/rules.d/
install -m 644 seekwave-fw-patch.service /etc/systemd/system/
udevadm control --reload
systemctl daemon-reload && systemctl enable --now seekwave-fw-patch.service
```

`--check` reports state, `--revert` restores stock. The udev rule fires on SDIO
card add, before the driver requests firmware; the service covers a card
enumerated before the rules were installed. Both are idempotent.

Images are matched by SHA-256. On anything else the script patches nothing and
exits non-zero, logging the offending hash at error priority:

```sh
journalctl -u seekwave-fw-patch -b
```

Not every byte is patchable: `0x2c890` and `0x57ea2` tolerate edits, `0x14f20`
makes the chip fail to boot. Test that the chip still boots after any new patch.
