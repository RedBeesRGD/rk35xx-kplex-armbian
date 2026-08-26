# The 6.0 Mbit/s uplink latch

Under CPU load the box's uplink drops to the 6.0 Mbit/s basic rate and stays there. Downlink is
unaffected. Only re-association recovers it. Measured 76.33 → 4.60 Mbps, a 16× collapse.

Decision and pointer live in `../../../artsense-arm/PLAN.md`; the patch is
`patches/0001-skw-txba-rearm-quirk.patch`; the reproducer is
`bench/wifi_latch_repro.sh`.

## Mechanism

`skw_setup_txba()` (`skw_core.c:203`) runs on **every TX frame**, called from the xmit path at
`skw_core.c:533`. Its only gate is a bitmap:

```c
if (peer->txba.bitmap & BIT(tid))
        return;
```

That bit is set optimistically when the ADD_TX_BA work is *queued* (`skw_core.c:234`), not when
the firmware confirms. The success event does not reconcile it — `skw_msg.c:920` acts only when
`ba->status_code` is non-zero. The sole recovery path is for an explicitly *refused* setup:
blacklist the TID, retry after 5 s.

There is no path for "the firmware stopped honouring the session and did not say so". When that
happens the bitmap claims a session that no longer exists, `skw_setup_txba()` returns early on
every subsequent frame, and the TID never renegotiates.

The rate consequence follows: HE data frames ride in A-MPDU, which requires a BA agreement, so
without one the TID loses HE entirely. The ladder strips legacy OFDM whenever the peer advertises
HE, leaving 1/2/5/6 Mbit/s legacy plus HE-MCS 0-11. With HE unusable the highest surviving rung
is exactly 6.0.

That also explains why this took so long to find. Rate control was correct throughout: it probed
the rung above, measured **196 attempts / 0 successes**, and correctly stayed put. Forcing HE with
`rcminrate` made throughput 14× *worse* (4.65 → 0.34 Mbps, ~1% efficiency) — HE was genuinely
unusable, not merely unselected. And there were no BA errors in the log because the driver was
not sending anything: it had nothing queued to fail.

The state is per-TID, not per-station. In the same second on one association:

    BE 3.80   BK 3.72   VI 51.16   VO 88.27 Mbit/s

VO ran HE-MCS 11 at 88 Mbit/s while BE could not exceed 4.

## Evidence: the firmware stops notifying at the failure

Measured directly with instrumented BA logging (`BADIAG` prints promoted to INFO in the event
handler, the command path and the arm site). Over a 300 s 2.4 GHz reproduction:

    54 DEL_TX_BA (all status 3)   53 ADD_TX_BA (all status 0)   54 arms

So BA sessions **churn constantly** — set up and torn down roughly every 5 s — and the firmware
reports those teardowns reliably. "The firmware never notifies" is false.

What fails is the *last* one. Per-TID, against a latch observed between t+170 s and t+180 s:

| TID | last BA activity | activity after the latch |
|---|---|---|
| **0 (BE)** | **t+168.6 s** | **none, for the remaining 130 s** |
| **6** | **t+168.0 s** | **none** |
| 1 | t+306 s | 5 full arm/ADD/DEL cycles |
| 4 | t+306 s | 10 full cycles |

TID 0's final event is an `ADD_TX_BA` with `status: 0` at t+168.6 s. No `DEL_TX_BA` follows, ever.
The bit stays set, `skw_setup_txba()` early-returns on every subsequent frame, and that TID never
renegotiates — while TIDs 1 and 4 carry on normally. That is the per-TID split (BE 3.80 vs
VI 51.16 Mbit/s) seen from the other direction.

This also puts a number on the re-arm interval. Natural session lifetime is ~5 s, so a 30 s
staleness threshold is 6× normal and cannot disturb healthy operation. That constant was
originally picked by guess; it is now measured.

### Two corrections to earlier claims here

The 2026-08-21 retraction ("silent teardown disproven") was over-broad: it generalised from the
**idle-timeout** path, where the firmware does send `DEL_TX_BA`, to the load-induced path.

But the replacement claim — "the firmware never notifies, `tidmap` was `0x1` at all 24 samples" —
was also wrong, and wrong for an avoidable reason. Sampling every 10-15 s cannot see a 5 s churn
cycle. Each `0x1` was a *freshly re-armed* session, not a stale one. Aggregate event counts were
just as misleading. Only the per-TID timeline settles it.

## What a real fix can use

The driver cannot *observe* the teardown. There is no DELBA/ADDBA action-frame handling anywhere
in it — BA is fully offloaded, `SKW_EVENT_BA_ACTION` is the only BA feedback — and no periodic
stats event exists (`SKW_EVENT_*` has none). The only rate feedback is the `SKW_CMD_GET_STA`
*response*.

So a **passively** rate-gated fix cannot work: `ctx->peer->tx.rate` is written in exactly one
place, `skw_cfg80211.c:2334`, inside the get_station handler. The first revision of the patch
gated on it and never fired unattended, and its apparent 22-attempt validation was contaminated —
the harness itself was calling `iw dev wlan0 link`, which issues the very get_station that
refreshes the field. Remove the observer and the fix evaporates.

An **actively polled** one can. The driver may issue `GET_STA` on its own schedule from work
context, and the same response carries both directions. During the latch they disagree
characteristically:

    TX: legacy 6.0            (skw_rate_info_flags LEGACY = 0)
    RX: HE-MCS 11, ieee80211ax (HE = 3)

`tx.rate.flags == LEGACY && rx.rate.flags > LEGACY` while `txba.bitmap` claims a session is a
precise signature of the fault: downlink proves the peer and channel still support HE, so a
legacy uplink means the TID lost aggregation. That fires only when actually broken, costs one
command per peer per interval, and needs no timer guess.

The blind timer (`patches/0001`) is **superseded** and should not ship. Its safety rested on BA
sessions being short-lived, which is an observation about this AP; against one that keeps a session
up for minutes it would renegotiate a healthy link every interval, forever.

It covers one case 0002 does not: 0002 requires `rx.rate.flags > LEGACY`, so on an HT-only or
legacy link it can never fire. Whether the fault occurs there is untested.

**Validated 3/3** by a paired test on a single association — disabled until a latch is confirmed by
real throughput, then enabled via sysfs with no reload and no re-association:

    4.65 -> 74.44 Mbps  (+10 s)     4.61 -> 77.76  (+20 s)     4.57 -> 75.29  (+30 s)

Each recovery coincides with the `stale TXBA` log. Latched links never recover unaided: control
arms held 18-21 consecutive samples at 6.0 and ended at 4.6-4.8 Mbps.

## Reproducing it

Three conditions, all necessary:

- **2.4 GHz** is where every reproduction has been done. Whether 5 GHz is immune is **untested** —
  see below; do not read this as a band finding.
- **Continuous load, not bursts.** 60 cycles of 60 s `stress-ng` produced zero latches, because
  the throughput probe between cycles re-trains the rate ladder each time.
- **Sparse traffic, ~2-3 pkt/s.** Not silence: windows carrying 8-17 packets never latched,
  because nothing is transmitted so nothing degrades. Not saturation either.

With all three, it latches at ~+75 s and holds through 285 s of load and 60 s of idle after.

**Disconnect ssh.** An interactive session is enough traffic to suppress it. Roughly 100 attempts
were wasted on windows that a login shell had quietly made unreproducible.

## 5 GHz

Tested properly at last — same module, same script, back-to-back arms with the quirk disabled and
the recipe that actually reproduces:

    2.4 GHz   78.25 -> 4.51 Mbps    LATCHED at t+180 s, TID 0 BA frozen from t+168.6 s
    5 GHz    450.55 -> 436.51 Mbps  healthy, TID 0 BA cycling 6-7x per 30 s for the full 300 s

The contrast is not just throughput: on 5 GHz the BA churn never stops, so the failure mode
itself did not occur. One run each, so this is evidence, not proof.

**Do not conclude 5 GHz is immune.** Two prior records disagree with each other:

- `EXPERIMENTS.md` (2026-08-20), a same-hour controlled A/B, agrees with the
  above — 5 GHz survived both `--cpu 4` and `--cpu 8 --io 4 --vm 2` + flood ping, 2.4 GHz latched
  in under 30 s. Signal was *stronger* on 2.4 GHz (-23 vs -32 dBm), so it is not a link-margin
  effect.
- `README.md` withdraws the band claim outright, on the grounds that the
  **originally reported failures were 5 GHz / 80 MHz**.

Reconciled: 2.4 GHz reproduces reliably and 5 GHz has never reproduced under a controlled A/B, but
the symptom was first seen in the field on 5 GHz. The likeliest reading is that 5 GHz needs
different or longer conditions, not that it is safe. The fix is not gated on band.

Earlier 5 GHz claims here were worthless in both directions and should be ignored:

- `validation.log`'s 5 GHz 0/3 sits in a file where **2.4 GHz also latched 0/5** — a null
  experiment, not a negative.
- `heavy.log` drove `ping -f -s 1400` — saturation, which suppresses the fault on 2.4 GHz too.
- `5240.963115` in `batrans2.log` and `4902.524063` in `batrans.log` are dmesg timestamps, not
  frequencies. They are not 5 GHz latch sightings.

The code path has no band-specific logic, so the quirk is not gated on band.

## Measurement traps hit along the way

- **`tx_bytes` counts frames the driver discarded.** It read 78× high and produced a completely
  false "fix". Caught only by physics — 228 Mbps claimed against a 143.3 Mbps PHY ceiling. Always
  confirm at the peer.
- **The control must be built the same way.** The vendor `.ko` is DKMS-stripped at 864 KB; a local
  build is 12.6 MB unstripped. Every cross-build A/B was confounded until a matched control was
  built from pristine upstream (`4da6222b1748` vs patched `874e7c73637a`, differing by 1,360 bytes).
- **`pgrep -f` matches your own ssh command line.** It reported a hunt "RUNNING" that had never
  started. Verify by artifact — a log file that grows — not by process name.
- **The box's watchdog cannot be stopped and carries across a soft reboot.** A dead-man
  `systemctl reboot` bricked it until power was pulled. See `watchdog.md`.

## Firmware: where the BA code actually lives

Mapped from the assert strings in `SWT6621S_IRAM_SDIO.bin`, which tag 59 source files onto
functions. The relevant split:

**In IRAM (readable, patchable) — only three `blockack.c` functions:**

| addr | what |
|---|---|
| `FUN_001174cc` | BA session config. Caps the window at `0x40` = 64 — the value the driver requests. Has an add path and a delete path that clears `+0x571`. |
| `FUN_00117904` | RX-side ADDBA *request* handler; allocates a 12-byte agreement slot |
| `FUN_00117778` | thin tail-call into ROM |

**In ROM (0x44000-0xdc656, ~610 KB, not in any shipped file):** the BA state machine itself —
`func_0x000be174`, `be618`, `be74c`, `d3864`, `d3a68`, `d1624`. The teardown decision and the
host notification are on that side. 2176 ROM call sites across 797 entry points.

### There is a hardware ROM patch unit, and it has free slots

`FUN_001137a0(rom_addr, word, slot)` drives a Seekwave patch block at `0x40002000`:

    0x40002014 + slot*4   <- (rom_addr - 0x40000) >> 2     address comparator, word-indexed
    0x40002200 + slot*4   <- replacement 32-bit word
    0x40002004 / 0x40002008 enable bitmaps (slots 0-31 / 32-63)
    0x40002000 |= 1, DSB, ISB, then 0xE000EF50 = 0         ICIALLU - I-cache invalidate

**64 slots**, replacing one 32-bit ROM word each. The replacement values in the shipped image are
Thumb-2 instruction encodings (`f640 510c`, `f88d 210d`, ...), so this is instruction patching, not
data. Ten are consumed at boot for BT/BLE ROM fixes, in slots 5-14; **roughly 54 are free**, and
ROM-to-IRAM is well inside a `B.W` branch range.

So a firmware fix is *architecturally* available: rewrite the offending ROM word, or branch out to
a stub in IRAM.

### What blocks it

We do not have the ROM. It is mask ROM inside the chip, not a file, so the teardown path cannot be
located or understood — and patching a 32-bit word you cannot read is not engineering.

Dumping it is the prerequisite, and the existing peek harness is far too slow (~3 s/byte; 610 KB
would take years). A faster primitive would have to be bootstrapped from the arbitrary write
(MIB 0x96) plus this patch unit — redirect something hot into a stub that copies ROM into a
host-readable window. That is a project, not a step.

Until then the driver-side fix is the shippable one.

### The file is the patch vector

Correcting an earlier claim here that a firmware patch is "not durable": it is. Both images are
loaded from disk into the adapter on every module load, so editing the file *is* the persistent
mechanism, and prior work already built the tooling (`tools/fwpatch.py`).

It is also cheap. The image is raw Cortex-M code — no header, no trailer, no checksum field — and
the driver CRCs whatever buffer it downloads, so patched bytes are covered automatically. Modules
reload in ~40 s with no reboot, and a recovery net exists on the box (`/root/fw-backup`,
`/usr/local/sbin/fw-restore`, `fw-guard.service`).

Two caveats: the board-suffixed firmware names are **symlinks** — resolve them, there are two real
files plus a `seekwave/` copy — and **not every byte is patchable**. A patch at `0x14f20` failed to
boot twice with `skw_boot_loader ret=-62`. Verify the chip boots after any new patch site.

Crucially the file also contains the ROM patch-slot installs (`FUN_00149b18`), so ROM behaviour is
reachable from the file too, by adding entries in the free slots.

The driver patch still ships first, for one reason that survives all of the above: 18 lines anyone
can audit versus a binary blob nobody can review.
