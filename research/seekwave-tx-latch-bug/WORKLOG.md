# Wi-Fi TX rate latch — lab notebook

Investigation of the SWT6621S 6.0 Mbit/s uplink latch on the H96 Max. Newest entry first. Past
entries are immutable — corrections go in a new entry, never a rewrite, so several entries below are
superseded by later ones and say so.

Outcome, mechanism and the shipped patches: `wifi-latch.md` · `patches/` · reproducer
`bench/wifi_latch_repro.sh`.

---

## 2026-08-23 — the latch reproduces on demand; the "silent teardown" retraction was wrong

**Reproduction recipe, 1/1 on first try after a fresh boot** (`bench/`-style script at
`~/skw/repro.sh` on the box):

- 2.4 GHz (2437), matched pristine control `4da6222b1748`
- `stress-ng --cpu 4 --timeout 300`, continuous
- traffic = **sparse only**: `ping -c 2` + `iw station dump` every 15 s. No bulk transfer.

Result: baseline 76.33 Mbps / HE-MCS 9 → holds to +60 s → **6.0 MBit/s at +75 s** → still 6.0 after
285 s of load and 60 s of idle. Confirmed by real bulk TX at the end: **4.60 Mbps**, 16× down.

### Why the previous ~100 quiet cycles found nothing

Two mistakes, both mine:

- **60 s bursts with a 4 s UDP probe between them.** The probe re-trains the rate ladder every
  cycle. `matched_hunt.sh` ran 60 such cycles, 0 latches. The ladder never got to descend.
- **Too quiet.** Those windows carried 8–17 tx packets. This one carried 791 over 285 s (~2.8/s).
  With _zero_ traffic nothing is transmitted, so nothing degrades. The fault needs sparse traffic
  under CPU starvation — not silence, and not saturation.

### The retraction of 2026-08-21 was over-broad

It disproved silent teardown on the **idle-timeout** path, where the firmware does send `DEL_TX_BA`
(bitmap 0x1 → 0x0, events present). That says nothing about the **load-induced** path. Measured
here:

- `tidmap = 0x1` at every one of 24 samples — before, during, after the collapse
- `BA events:` section of the log is **empty**. Zero `ba_action` lines in 400 s.

So on this path the firmware stops honouring the session and never notifies. `skw_setup_txba()`
(`skw_core.c:203`) is called on **every TX frame** from the xmit path (`skw_core.c:533`) and returns
immediately at `if (peer->txba.bitmap & BIT(tid)) return;`. The bit is set optimistically when the
work is _queued_ (`skw_core.c:234`); the success event does not reconcile it. The only existing
recovery is for an explicitly refused setup — blacklist + 5 s retry. There is no path for "firmware
lost it silently".

### Corollary from source: a rate-gated fix cannot work

`ctx->peer->tx.rate` is written in exactly one place, `skw_cfg80211.c:2334`, inside the get_station
handler. No periodic firmware push exists. That is why v1 never fired unattended — proven from
source now, not just inferred from the failed run.

### ~~5 GHz looks genuinely unaffected~~ — **withdrawn same day, the negatives are null**

Original claim: `heavy.log` ran a harsher stimulus on 5 GHz — `--cpu 8 --io 4 --vm 2` plus a flood
ping, 240 s — and never left `600.4 MBit/s 80MHz`, so every latch on record is 2.4 GHz.

That does not hold. `heavy.log` drove `ping -f -s 1400` — _saturation_, which suppresses the fault
on 2.4 GHz too. And `validation.log`'s 5 GHz-stock 0/3 sits in a file where **2.4 GHz-stock latched
0/5**: a null experiment, not a negative.

Two old "5 GHz latch" sightings were also misreadings — `5240.963115` and `4902.524063` are dmesg
timestamps, not frequencies.

5 GHz has never been run with continuous load + sparse traffic. **Untested, not immune.**

### Firmware: BA is mostly ROM, but there is a 64-slot ROM patch unit

Mapped 59 source files onto functions via the assert strings in the IRAM image. `blockack.c` **is**
in IRAM — but only three functions: `FUN_001174cc` (session config; caps window at `0x40` = 64, the
value the driver asks for), `FUN_00117904` (RX ADDBA request handler), `FUN_00117778` (ROM
tail-call). The BA **state machine and teardown are in ROM**
(`func_0x000be174/be618/be74c/d3864/ d3a68/d1624`), 0x44000-0xdc656, ~610 KB, not shipped as a file.

`FUN_001137a0(rom_addr, word, slot)` drives a patch block at `0x40002000`: address comparator
`(rom_addr - 0x40000) >> 2`, a replacement 32-bit word, enable bitmaps, then DSB/ISB and
`0xE000EF50 = 0` — ICIALLU. **64 slots, instruction-level.** Replacement values in the image are
Thumb-2 encodings. Ten used at boot for BT/BLE (slots 5-14); **~54 free**.

So a firmware fix is architecturally available. It is blocked on **not having the ROM** — patching a
word you cannot read is not engineering. Dumping first would need a faster primitive than the ~3
s/byte peek (610 KB → years), bootstrapped from MIB 0x96 arbitrary write + this patch unit.

### Band: my 5 GHz reading agrees with one prior record and not the other

`EXPERIMENTS.md` 2026-08-20 ran a same-hour A/B: 5 GHz survived both stimuli, 2.4 GHz latched in
under 30 s, with signal _stronger_ on 2.4 GHz (-23 vs -32 dBm) — so not link margin. That matches
today. But `README.md` withdrew the band claim because **the originally reported field failures were
5 GHz / 80 MHz**.

Reconciled: 2.4 GHz reproduces reliably; 5 GHz has never reproduced under a controlled A/B; the
symptom was first seen on 5 GHz. Read as "5 GHz needs different conditions", not "5 GHz is safe".

### Instrumented BA trace — the mechanism, exactly

`BADIAG` prints at INFO in the event handler, the command path and the arm site. 300 s, 2.4 GHz,
quirk disabled:

    54 DEL_TX_BA (status 3)   53 ADD_TX_BA (status 0)   54 arms

BA churns every ~5 s and **the firmware reports those teardowns reliably**. Per TID, latch between
t+170 and t+180:

| TID        | last BA activity | after the latch    |
| ---------- | ---------------- | ------------------ |
| **0 (BE)** | **t+168.6 s**    | **nothing, 130 s** |
| **6**      | **t+168.0 s**    | **nothing**        |
| 1          | t+306 s          | 5 cycles           |
| 4          | t+306 s          | 10 cycles          |

TID 0's last event is an `ADD_TX_BA` status 0; no `DEL_TX_BA` ever follows. Bit stuck set →
`skw_setup_txba()` early-returns forever → that TID never renegotiates, while 1 and 4 carry on. The
per-TID split, from the other side.

**Two of my own claims died here.** "Firmware never notifies" — false, it notifies 54 times. And the
`tidmap 0x1` evidence I leaned on was an artefact: sampling every 10-15 s cannot see a 5 s churn, so
every `0x1` was a _fresh_ session, not a stale one. Only the per-TID timeline settles it.

Silver lining: the 30 s constant is now justified rather than guessed — natural lifetime ~5 s, so 30
s is 6× normal and a healthy link never reaches it. The quirk is a staleness timeout, not a blind
periodic re-arm.

### 5 GHz, tested properly at last

Same module, same script, back-to-back, quirk off, correct recipe:

    2.4 GHz   78.25 → 4.51 Mbps    LATCHED, TID 0 BA frozen from t+168.6 s
    5 GHz    450.55 → 436.51 Mbps  healthy, BA cycling 6-7× per 30 s for all 300 s

Evidence, not proof — one run each. But it is the first 5 GHz arm that wasn't a null experiment.

### 2026-08-25 — 5 GHz made the default, with fallback

Box was on 2437 only because my test scripts left a runtime `freq_list` set; netplan had no band
constraint at all. Now preferred properly: `/usr/local/sbin/wlan-prefer-5ghz` rewrites
`/run/netplan/wpa-wlan0.conf` into two network blocks — 5 GHz-restricted at `priority=10`, the
unrestricted original at `priority=1` — driven by an `ExecStartPre` drop-in on
`netplan-wpa-wlan0.service`.

Preference, not a pin: a hard `freq_list` would leave this headless box unreachable if 5 GHz
vanished, and it has already needed a physical power cycle once.

    2.4 GHz  2437, HE-MCS 9,  20 MHz   ~80 Mbps
    5 GHz    5200, HE-MCS 11, 80 MHz   433.42 Mbps

Persistence verified without rebooting (watchdog risk): restored a pristine netplan conf with no
`freq_list`, restarted the service, and the hook re-applied it — 5200 MHz, 430.26 Mbps. That is the
same path taken at boot.

5 GHz BSS is `<redacted-bssid>` at -33 dBm, stronger than the 2.4 GHz radio at -44.

### 2026-08-25 — dmesg noise: `force` defeats the dump log control

1659 of 1678 driver log lines over two days were one message: `short skb` from
`skw_ndo_start_xmit()`. `/proc/skwifid/log_level` said `dump log: disable` the whole time.

Cause: `skw_hex_dump(prefix, buf, len, force)` is `if ((skw_log_level() & SKW_DUMP) || force)`. Five
per-packet sites pass `force = true`, so the gate never applies. Most of the driver (40 sites)
correctly passes `false`.

`patches/0003` passes `false` at those five. Left alone: one at wiphy init and three reachable only
from private ioctls — all bounded.

Measured after: `dmesg -C`, traffic, 3 min → **9 total lines, 1 driver line, 0 `short skb`**. Dumps
still available by enabling `dump` in `log_level`.

### 2026-08-25 — what the `short skb` frames are: wpa_supplicant, not firmware

Captured with debug+dump for 600 s. 10 events, **all `current: wpa_supplicant`**, interval a dead
regular **10 s**, frame byte-identical every time:

    74 90 bc 12 33 90  fe fd fc 28 fc 8e  08 00
    dst = AP BSSID     src = our MAC      ethertype 0x0800 (IP)

14 bytes — bare Ethernet header, zero payload. It arrives via `skw_ndo_start_xmit`, so it is a raw
`l2_packet` socket, not the nl80211 poll path. wpa_supplicant v2.10.

The driver **drops every one** (`goto free`) and deliberately does not warn: the `SKW_BUG_ON` is
skipped for exactly this shape (`len == ETH_HLEN && proto == ETH_P_IP`). Hence zero WARNs in 2 days
despite ~8,600 events/day.

So the poll never reaches the air. The drops **are** accounted for — `ret` is `-1` at function
entry, so the path reaches `dev->stats.tx_dropped++`; confirmed as `tx dropped 250` and climbing on
`ip -s link show wlan0`.

The driver cannot stop wpa_supplicant emitting these: it is a fixed 10 s timer that fires regardless
of outcome. Padding and transmitting (`skb_put_padto`) would make the poll real but not rarer, and
would put a zero-payload IP frame on the air every 10 s. Post-`0003` the arrangement is already the
right one — silent in dmesg, counted in `tx_dropped`, dumps available by enabling `dump` in
`log_level`.

Not a firmware issue; the images are not involved. Why wpa_supplicant emits it is not established.

### Field check, 2026-08-25 — 2 days unattended

Box up 2 days 5 h on the shipped fix (`6c9ba7462da9`, `txba_stale_sec=10`, DKMS clean, no
`modprobe.d` needed). `stale TXBA` fired **2 times** — two real stale sessions detected and
renegotiated with nobody watching. Link healthy at HE-MCS 9 / 65.93 Mbps, no latch.

### v3 condition-driven fix — **validated, 3/3**, by a paired test

Arm-vs-arm was underpowered (fault hits ~50-65% of 300 s arms), so I stopped running arms and used
the fact that `txba_stale_sec` is runtime-writable: run with the check **disabled** until a latch is
confirmed by real throughput, then enable it via sysfs — no reload, no re-association, same link,
same load, same binary.

| latched   | after enabling | recovered |
| --------- | -------------- | --------- |
| 4.65 Mbps | **74.44**      | +10 s     |
| 4.61 Mbps | **77.76**      | +20 s     |
| 4.57 Mbps | **75.29**      | +30 s     |

Every recovery coincides with `stale TXBA`. In the third the first check did not take and the second
did (`stale-fired` 1→2 at +20 s, recovery at +30 s). Control arms never self-recover: 18-21
consecutive samples at 6.0, ending 4.6-4.8 Mbps.

Arm-vs-arm for the record: control 3/5 latched, enabled 0/5 (Fisher p≈0.08 — suggestive only). **The
paired test is the load-bearing evidence**; it removes every confound the arm tests had.

### v3 — the earlier null run (superseded by the above)

`patches/0002-*.patch`, 87 insertions. Suspicion (BA claimed > `txba_stale_sec`, default 10 s)
confirmed by `tx.rate.flags == LEGACY && rx.rate.flags > LEGACY` before clearing. Builds clean.

Its A/B was **null**: the control arms (`txba_stale_sec=0`, stock behaviour) latched **0/2**. No
fault, nothing demonstrated. The enabled arms' 20 s dips are probably ordinary rate wobble —
`stale TXBA` fired 0 times in one of them, so the deadline was never reached.

**The reproduction is session-dependent.** 4/4 earlier the same day, 0/2 a few hours later with an
identical script. That intermittency, not the code, is the bottleneck.

### A/B/A/B on matched builds — the fix works

Interleaved so RF drift cannot pass for an effect. 240 s load per arm, PHY sampled every 10 s,
throughput measured once after load stops. Control `4da6222b1748`, patched `874e7c73637a`, same tree
and toolchain, 1,360 bytes apart.

| arm       | first dip | at 6.0 | recoveries under load | before → after    |
| --------- | --------- | ------ | --------------------- | ----------------- |
| control-1 | +50 s     | 18/22  | 0                     | 69.74 → **4.73**  |
| patched-1 | +100 s    | 6/22   | **7**                 | 72.30 → **62.18** |
| control-2 | +50 s     | 18/22  | 0                     | 67.04 → **4.59**  |
| patched-2 | +100 s    | 5/22   | **8**                 | 62.65 → **69.74** |

The discriminator is _recoveries under load_: the control sat through 18 consecutive 6.0 samples
with zero bounce-backs in both arms; the patched arms bounced back 7 and 8 times with `stress-ng`
still running, and both finished on HE-MCS 9. End state differs 13–15×.

Both control arms also latched at +50 s here vs +75 s in the first run — the fault is not marginal
once the three conditions are met.

---

## 2026-08-21 (later, 5) — TX-rate latch removed from the project docs; it is a separate problem

Decision from the user: assume the latch gets fixed, and stop letting it shape the berry-picker
design. Stripped from `PLAN.md` and `docs/`. Past worklog entries stand — they are the evidence
trail for the _other_ problem, and this directory remains its home.

### What came out

- Hardware limits: the "WiFi firmware latches TX low (watchdog installed)" clause.
- Transport: the latch bullet, and the "firmware root cause parked / three mitigations" bullet.

### What stayed, re-justified without it

- **DSCP VI (0xa0)** — correct marking for realtime traffic on its own merits. `PLAN.md` always said
  the latch immunity was "a bonus, not the reason"; now it is only the reason.
- **5 GHz** — more headroom, less contention. Ordinary practice, no bug required.

### The one real casualty, and it came out stronger

`vision-anchor.md` argued vision-loss tolerance from the latch being this box's measured failure
mode. That prop is gone, but the load-bearing number never depended on it: video is **364x**
control + proprioception, so **the link can lose 99.7% of its throughput before the arm's own loop
is touched**. Re-grounded on that instead — contention, interference, RSSI change as the arm moves,
retry bursts, a slow inference tick, a dropped USB frame. All of them starve vision and leave
control alone.

Structural, not a fault awaiting a fix. And cloud inference — which `PLAN.md` keeps open — sharpens
it, since an internet uplink is far more variable than a LAN. Frame gating already delivers vision
irregularly by design, so this extends an existing range rather than adding a mode.

**Tying a durable design principle to a specific bug was the error.** The bug was the thing that
made the principle _visible_, not the thing that makes it true.

---

## 2026-08-21 (evening) — **retraction: the "silent teardown" mechanism is disproven**

Measured directly, with DEBUG logging on:

    tidmap after traffic : 0x1
    tidmap after 45s idle: 0x0
    events               : ADD_TX_BA tid0 st0 / DEL_TX_BA tid0 st3, repeatedly

**The firmware does send DEL_TX_BA, and the driver clears the bitmap correctly.** So "firmware drops
the session silently, the driver never learns, the bitmap goes stale" is **wrong**. Teardown
notification works.

### What that costs

The causal chain claimed earlier -- stale bitmap -> no BA -> no A-MPDU -> no HE -> 6.0 Mbit/s -- is
no longer supported. It was an inference built on the assumption that no DEL_TX_BA arrives.

### What survives, measured

- Forcing an `ADD_TX_BA` (by clearing `txba.bitmap`) recovers a latched link: 4/4, 3.75 -> 109
  Mbit/s, live, no re-association.
- **Why** it recovers is unknown. Could be BA renegotiation; could be a side effect of issuing the
  command at all.
- HE fails 196 attempts / 0 successes while legacy runs 89-96% on the same TID.
- Per-TID: BE 3.80 / BK 3.72 vs VI 51.16 / VO 88.27 Mbit/s on one association.
- The ladder holds `1/2/5/6` legacy + HE-MCS 0-11, so 6.0 is the only rung left when HE is unusable.

### Also retracted this session

v1 of the driver change gated on `peer->tx.rate.flags`, which only refreshes on a `get_station`
query. Unattended it never fired. The 22-attempt validation that "confirmed" it was contaminated --
the test harness called `iw dev wlan0 link` constantly, refreshing the very field the guard read.

### Status

`patches/0001-...patch` is marked **DO NOT SUBMIT**. Root cause is not established. The reproduction
has also gone quiet (0 latches in 16 attempts today), which blocks further diagnosis until it
returns.

`~/skw/latchwatch.sh` is running on the box, sampling every 5 min, to catch a natural latch.

---

## 2026-08-21 — consolidated validation of the TX BA fix

Formal interleaved A/B was cut short when the control host left the network; the patched arm of
block 1 and all of block 2 are **not** done. Everything below is complete and measured.

### Root cause, 4/4 — clearing the stale bit recovers the link

Every latch showed `bitmap: 0x1`, i.e. the driver believed the BA session was established.

| run | latched     | after clearing the bit |
| --- | ----------- | ---------------------- |
| 0   | 3.75 Mbit/s | 109.18                 |
| 1   | 4.13        | 111.21                 |
| 2   | 4.11        | 111.28                 |
| 3   | 4.14        | 105.46                 |

`blacklist` varied (0x10, 0x0) across these, so the blacklist is incidental — it is the bitmap.

### Automatic fix — 22 attempts, 0 sustained latches

    run A (patched module) 13 attempts: 1 transient dip, self-healed <10 s (4.52 -> 90.08 -> 111.91)
    run B (cold boot)       9 attempts: 1 transient dip, self-healed <10 s (4.66 -> 71.67 -> 110.70)

Run B matters most: rebooted, patched module loaded from disk, **stock firmware**, MAC pinned, and
it self-healed unaided. That is the deployed configuration, not a lab rig.

### Stock control — latches and never recovers

Three samples per attempt, which separates "pinned" from "recovering slower than one sample":

    a1: 4.50 -> 5.08 -> 5.15 Mbit/s   flat across 60 s
    a2: 4.84 -> 4.87 -> 4.88 Mbit/s   flat across 60 s
    latched 2/5, recovered unaided 0/2

### Mechanism evidence (measured, not inferred)

- HE: **196 attempts, 0 successes**; legacy on the same TID: 89-96%
- forcing HE with `rcminrate` made throughput **14x worse** (4.65 -> 0.34 Mbit/s, ~1% efficiency)
- per-TID on one association: BE 3.80 / BK 3.72 vs VI 51.16 / VO 88.27 Mbit/s
- ladder decoded: `1/2/5/6` legacy + HE-MCS 0-11, **no OFDM above 6** -> 6.0 is the only surviving
  rung

### Still untested

Patched arm of the formal A/B, block 2, **5 GHz**, long soaks, other APs and peers. The mechanism is
band-agnostic (no band logic in `skw_setup_txba`) and a 5 GHz latch was observed on stock at the
same 6.0 Mbit/s floor, so 5 GHz is expected to behave identically — expected, not yet demonstrated.

### Measurement rules earned the hard way

- **Peer-confirmed TCP only.** `tx_bytes` counts frames the firmware consumed _including discards_
  and produced a 78x false positive (`txlftm`: counter 191.95 vs real delivery 2.47 Mbit/s).
- **Sample three times per attempt.** Single-shot cannot tell a pin from slow recovery.
- **Re-verify the control immediately before each run.** This stimulus goes quiet for whole windows.
- **Re-apply `rk35xx-mac-pin` after every module reload**, or the box changes MAC and IP mid-test.

---

## 2026-08-21 — **FIXED. Self-healing verified 13/13. Driver patch, not firmware.**

    cycle 1: dipped 4.52 Mbit/s -> 90.08 at +10s -> 111.91, stable to +60s
    cycle 2: 6 stimulus attempts, no dip
    cycle 3: 6 stimulus attempts, no dip

13 stimulus attempts with the patch: **one transient dip that self-healed in under 10 s** (matching
`SKW_TXBA_RECHECK_INTERVAL`), twelve with no dip at all. Stock latches ~60% of attempts and never
recovers — 150 s soaks never moved off ~4 Mbit/s. Healthy throughput unchanged at 108–113 Mbit/s, so
no regression.

Patch: `patches/0001-skw-recover-silently-dropped-tx-ba-session.patch`, 49 lines, two files. Applied
to `/usr/src/seekwave-swt6621s-1.0.0` so it survives DKMS rebuilds; originals kept as `*.orig`.

    skw_iface.h   +1 field   unsigned long recheck[SKW_NR_TID];
    skw_core.c    +23 lines  detect + renegotiate in skw_setup_txba()

Manual-reset validation before the automatic version, 4/4:

| run | latched     | after clearing the bit |
| --- | ----------- | ---------------------- |
| 0   | 3.75 Mbit/s | 109.18                 |
| 1   | 4.13        | 111.21                 |
| 2   | 4.11        | 111.28                 |
| 3   | 4.14        | 105.46                 |

Every one showed `bitmap: 0x1` — BA believed established — and `blacklist` varied (0x10, 0x0), so
the blacklist is incidental. It is the bitmap.

**Not tested:** 5 GHz, other APs, other peers, long-term soak. The detection fires on "BA believed
up while TX rate is legacy", which is also briefly true right after association on a legacy-only
link; the 10 s rate limit bounds that to one extra renegotiation.

---

## 2026-08-21 — **ROOT CAUSE: stale `txba.bitmap` in the driver. Not a firmware bug.**

    LATCHED:       3.75 Mbit/s  [6.0]      tidmap: 0x1, legacy_rate: 60, legacy
    after reset: 109.18 Mbit/s  [143.3]    tidmap: 0x1, mcs: 11, ieee80211ax

    skw_setup_txba: forced TXBA reset, tid: 0, bitmap: 0x1, blacklist: 0x10

**29x recovery, live, no reassociation.** Driver source is on the box at
`/usr/src/seekwave-swt6621s-1.0.0` (DKMS), with headers + gcc + make, so this is a source fix.

### The defect

`skw_setup_txba()` sets `peer->txba.bitmap |= BIT(tid)` when the ADD_TX_BA work is **queued**, not
when the firmware confirms the session. The bit is cleared only on:

- `skw_send_msg` failure (skw_work.c)
- an `SKW_ADD_TX_BA` event carrying a non-zero `status_code`
- an explicit `SKW_DEL_TX_BA` event

When the firmware drops a BA session **silently** — no DEL_TX_BA — the driver has no path to learn
it. The bit stays set, `skw_setup_txba()` returns early forever, and the TID never renegotiates.

HE data frames are carried in A-MPDU, which requires a BA agreement, so that TID can no longer use
HE at all. The ladder strips legacy OFDM whenever the peer advertises HE, so the highest surviving
rung is **6.0 Mbit/s** — exactly the observed floor.

### Why everything else looked wrong

| observation                          | now explained                                     |
| ------------------------------------ | ------------------------------------------------- |
| no BA events while latched           | driver never queues a request; it thinks BA is up |
| no `setup TXBA failed` while latched | nothing is sent, so nothing can fail              |
| HE 196 attempts / 0 success          | no BA -> no A-MPDU -> HE unusable                 |
| forcing HE made it 14x worse         | forces frames onto a path that cannot work        |
| per-TID (VI/VO fine)                 | `txba.bitmap` is per-TID                          |
| reassociation is the only cure       | peer teardown resets the whole txba struct        |
| rate control measured correctly      | it was never the faulty component                 |
| ten firmware patches all failed      | the bug is in the driver, not the firmware        |

`tidmap` in `/proc/skwifid/chip1.sdio/wlan0` **is** `txba.bitmap` (skw_iface.c:136) — the BA state
was visible in every measurement taken this session.

### Status

Confirmed once, 3-cycle replication running. Test vehicle is a one-shot module param
(`skw_force_ba_reset`) added to `skw_core.c`; the production fix must clear or re-arm the bit
automatically rather than manually.

---

## 2026-08-21 — **two defects: HE fails (root), and one dead rung walls off the ladder (amplifier)**

### The ladder is ordered by rate code, interleaving legacy and HE

With `ofdm keep` the OFDM rates return and the ordering becomes visible:

    index:  4        5         6         7
    code:   13       17        20        25
    rate:   9.0 leg  HE-MCS 0  12.0 leg  HE-MCS 1

Measured while latched at 9.0 (`aa=4`, stats wipe disabled so counters accumulate):

    attempts:  index 4 = 246   index 5 = 88   index 6 = 0
    pct:       index 4 = 89%   index 5 = 0%   index 6 = --

**Index 5 (HE-MCS 0) took 88 attempts and never once succeeded. Index 6 (12.0 legacy) was never
attempted at all.**

### Why it cannot climb

Rate control probes only `current + cfg[0x29]`, and `cfg[0x29]` is measured = **1**. From index 4
the only probe target is index 5, a dead HE rate. It fails, the controller retreats, and index 6 — a
legacy rate that works — is never reached. **A single failing rung between two working rungs walls
off the entire ladder above it.**

That is a genuine design flaw: a minstrel-style controller samples across the ladder, not just the
adjacent entry. With a step of 1, any one broken rate is an impassable barrier.

### Two separate defects

|     | defect                                                     | status                            |
| --- | ---------------------------------------------------------- | --------------------------------- |
| A   | HE fails on the TID after the stimulus                     | root cause, still unexplained     |
| B   | probe step of 1 makes one dead rung block everything above | measured, and testable at runtime |

Stock hides B because the ladder has no OFDM rates: above 6.0 everything is HE, so a bigger step
lands on another failing HE rate. With `ofdm keep` the working legacy rungs exist but are
unreachable — which is exactly why the patch moved the pin only 6.0 -> 9.0, one rung.

### Correction

`ofdm keep` was previously recorded as refuted because it "still pinned, at 9.0". That was wrong:
the move from 6.0 to 9.0 is the ladder stepping onto the next OFDM rung, i.e. the patch working.
Measured interleaved against stock: stock 4.89 Mbit/s at 6.0, `ofdm keep` 7.26 Mbit/s at 9.0, and it
took three stimulus attempts to degrade instead of one.

Efficiency also rules out an airtime cap: legacy delivers ~82% of PHY at both 6.0 and 9.0, while
forced HE-MCS 2 delivered 1.3%.

---

## 2026-08-21 — **mechanism: the BE Block-Ack session is gone and never re-established**

Traced `skw_event_ba_action` at DEBUG across 60 s windows of BE traffic, firmware freshly reloaded
so no knob is left set (a stale `rcminrate` contaminated the previous attempt).

    HEALTHY (104 Mbit/s, HE-MCS 11)      LATCHED (4.06 Mbit/s, 6.0 legacy)
      tid 0: add=1 del=0  <- stays up      tid 0: NO EVENTS AT ALL
      tid 1: add=5 del=5  life 0.96s       tid 1: add=1 del=1  life 0.65s
      tid 6: add=1 del=1  life 1.66s

Healthy: the BE (tid 0) BA session is established once and never torn down. Latched: **tid 0 has no
BA activity whatsoever** — the firmware is not failing to set up a session, it never attempts one.

No BA agreement -> no A-MPDU -> no HE (HE data frames are carried in A-MPDU) -> the ladder's highest
non-HE rate, which the decoded table shows is exactly **6.0 Mbit/s**.

### This accounts for every observation

| observation                                  | explained by                                    |
| -------------------------------------------- | ----------------------------------------------- |
| per-TID (BE/BK pinned, VI/VO at HE-MCS 11)   | BA agreements are per-TID; VI/VO keep theirs    |
| HE fails 196/196, legacy works 89-96%        | HE needs A-MPDU; legacy does not                |
| forcing HE via `rcminrate` made it 14x worse | forces frames onto a path with no BA            |
| RX stays HE-MCS 10                           | that is the AP's originator session, unaffected |
| reassociation is the only cure               | fresh association re-establishes BA             |
| MIB 0x50 does nothing                        | it rebuilds the rate ladder, not BA state       |
| 150 s of true idle does nothing              | nothing drives BA re-setup                      |
| rate control measured 196/0 correctly        | it was right; HE genuinely does not work        |
| every rate-control patch failed              | rate control was never the faulty component     |

### Correction to the earlier trace

The previous run showed tid 0 ADD/DEL "thrashing". That was `rcminrate` still forcing HE, so the
firmware kept attempting BA setup and failing. Left alone it simply stops attempting.

---

## 2026-08-21 — **rate control exonerated by experiment: forcing HE makes it 14x worse**

### The rate ladder, decoded

Patched `FUN_0012c714` to return `&rate_table[cfg[0x2b]]` with the code steerable at runtime, so the
**driver's own decoder** prints what each ladder code means. No latch needed — a static table read.

    index 0..3  : codes 0, 2, 7, 9   -> 1.0, 2.0, 5.0, 6.0 Mbit/s legacy
    index 4..15 : codes 17 .. 56     -> HE-MCS 0 .. HE-MCS 11

The ladder holds **no OFDM rates above 6 Mbit/s** — no 9/12/18/24/36/48/54. That is the `ofdm` path
at 0x12d38c doing its job: OFDM rates are dropped when the peer advertises HE.

So **6.0 Mbit/s is the highest non-HE rate that exists in the ladder**. Pinning there is not a
misjudgement; it is the correct choice if every HE rate fails. This finally explains why the pin is
always exactly 6.0 and never an intermediate rate.

### Forcing HE (rcminrate, MIB 0x50) — all peer-confirmed TCP

    control:        96.20 Mbit/s  [HE-MCS 11]
    LATCHED:         4.65 Mbit/s  [6.0 Mbit/s]
    rcminrate=0x33 → 0.34 Mbit/s  [25.8 Mbit/s HE-MCS 2]
    rcminrate=0x35 → 0.59 Mbit/s  [51.6 Mbit/s HE-MCS 4]
    after reassoc:  93.47 Mbit/s  [HE-MCS 11]

Forced to a 25.8 Mbit/s PHY rate, actual delivery is **0.34 Mbit/s — about 1% efficiency**. HE is
genuinely unusable on the latched BE TID, so rate control's 196-attempts / 0-success measurement was
**correct**. It avoids HE because HE does not work.

**The fault is in the HE TX path for that TID, not in rate selection.** Every rate-control patch in
this project was therefore always going to fail, which is exactly what happened to all of them.

### Why Block Ack is back as the suspect

HE data frames are carried in A-MPDU framing, and A-MPDU requires a BA agreement. A broken BE BA
session produces precisely this signature: HE fails, legacy (non-aggregated) works, VI/VO keep their
own sessions and run HE-MCS 11, and RX is unaffected because that is the AP's originator session.
The earlier `mppdudur` result does **not** rule this out — limiting PPDU duration does not establish
or repair a BA agreement.

---

## 2026-08-21 — **INCIDENT: box wedged by live firmware knobs, needs a power cycle**

Setting `txrtycnt=31` then `rcsperate=1` via the private ioctl on a live link left wlan0
unreachable. No ping, no ssh, 10+ minutes. The box is WiFi-only (`end0` down), so the management
path runs over the very interface those TX-path knobs control.

**Recovery: power-cycle the box, or plug ethernet into `end0`.** Firmware config is volatile,
nothing was written to disk, and `/lib/firmware` holds stock `89ffe0b0d9b7` (verified before the
run). No persistent damage.

### What went wrong

- Fed **untested TX-path knobs** to a device whose only access path is the interface they configure.
- The **dead-man reboot timer had been cancelled** earlier in the session, after it fired
  inconveniently and rebooted the box mid-test. It existed for exactly this case.
- The run was void anyway: its "healthy" baseline measured 4.71 Mbit/s, i.e. the link had already
  re-latched before the first knob was applied. No control, so every knob result is meaningless.

### Rules for next time

1. **Always arm a dead-man reboot** before touching firmware knobs. Never cancel it while knobs are
   in play; set it long rather than removing it.
2. **Verify the control immediately before the run**, not minutes earlier — this stimulus re-latches
   on its own, and a stale baseline silently voids everything after it.
3. Treat `txrtycnt`, `rcsperate`, `txlftm`, `edca`, `mppdudur` as **capable of severing access**.
   Anything touching the TX path needs the dead-man armed and a same-session justification.

---

## 2026-08-21 (later still) — `txlftm` "fix" was a counter artifact; **verify delivery, not counters**

`txlftm=10` appeared to restore a latched link to 214-228 Mbit/s. It does not. Peer-confirmed TCP at
the same instant:

    after txlftm=10:  UDP tx_bytes probe 191.95 Mbit/s   vs   real TCP delivery 2.47 Mbit/s

A 78x discrepancy. `tx_bytes` increments when the firmware **consumes** a frame, including frames it
discards. A short TX lifetime discards aggressively, so the counter races while delivery _drops_ —
2.47 Mbit/s is worse than the 4.71 latched baseline. `txlftm=255` -> 13 Mbit/s is void for the same
reason.

The tell was physics: 228 Mbit/s is impossible on 2.4 GHz / 20 MHz / HE-MCS 11 / NSS 1, which caps
at 143.3. Healthy 104 (~73% of PHY) is plausible; 228 is not.

**Scope of the damage.** The UDP probe stays valid on _unmodified_ firmware — its readings track TCP
closely there (78 TCP vs ~100 UDP healthy; 5.17 vs ~4 latched). It only lies when a knob causes mass
discard. Latch detection and all firmware-state measurements are unaffected.

Sixth instrument defect this session, and the only one that produced a **false positive**. The
others hid results; this manufactured success. At 228 Mbit/s the impossibility was obvious — at 120
it would have shipped.

**Rule going forward: a throughput claim needs peer-confirmed delivery. Interface counters prove
only that the firmware accepted the frame.**

### Also enumerated: the driver's full private-ioctl surface

Sending a bogus subcommand returns a usage listing:

    bandcfg mppdudur edca ccanowifi cca11b ccaofdm rtsrate rxrsprate scantime tcpdwhost
    rcminrate rcratechg rcsperate txlftm txrtycnt txrtsthrd rxsped11frm rxupdnav
    apgotimap dbdcdis addrval rdaddr ageout params tidtxlifetm

`rdaddr` is confirmed dead — firmware returns nothing
(`SKW_CMD_SET_MIB expect len: 4, recv len: 0`). `tidtxlifetm` rejects every argument format tried.
`edca=0,x(13 total)` is per-AC and untested.

---

## 2026-08-21 (later) — **rate control is innocent: the rate above the pin fails 100% on air**

Built a runtime-steerable peek — the target address lives in `cfg[0x2a]/[0x2b]`, written by MIB 0x51
(`rcratechg`), which does **not** trigger firmware recovery. So arbitrary context bytes can be read
on a live latch, ~3 s each, instead of one byte per firmware reload (~8 min). Validated against
known values (`ctx[0x63]=56`, `ctx[0xa4]=15`) before use.

Then disabled the per-rate stats wipe (`bl 0x13dfae` -> nops) so the counters accumulate and can be
read at all — with the wipe in place they read 0 almost always, which is why every earlier stats
sweep was uninformative.

### The measurement

Latched, `aa=3`, after a 60 s saturated soak:

    index j:      0    1   2    3     4    5   6   7
    attempts:   172    0   0   164   196   0   0   0
    pct:         96    0   0    89     0   0   0   0
    warm:         1    0   0     1     1   0   0   0

**Index 4 took 196 attempts and succeeded 0 times.** Index 3 (the pinned rate) runs at 89%, index 0
at 96%. Index 3 is legacy 6.0; index 4 is the first HE rung (the `8.6 Mbit/s HE-MCS 0` seen in every
descent). So **HE rates fail completely while legacy rates work.**

Rate control is therefore behaving _correctly_: it probes the rung above, measures 0% success, and
stays put. This explains every dead end at once —

- why nine rate-control hypotheses all measured normal: none of them was the faulty component
- why `clamp zero` made the rate oscillate 5.0 <-> 6.0 but never climb: probes fire and fail
- why the ladder is intact and never used above index 3
- why 150 s of saturation changes nothing
- why `psr` stays 92-99 at the pinned rate: legacy genuinely works

### Corrections

- The Block-Ack teardown theory is **not supported**: `ba_action` events = 0 in both states.
- `[BE] stoped: 1, tx_cache: 774` while latched is a _consequence_ — saturating a 6 Mbit/s link
  trips flow control regardless of cause. Not evidence.
- One VI measurement came back 10.36 Mbps, not the 109 measured earlier, so the per-TID claim is
  unconfirmed pending a verified-TOS retest.

### Refuted with trustworthy instruments

`clamp nop`, `clamp zero`, attempt gate `cfg[0x25]=1` (measured stock value 3), and the panic-flag
variants. All were scored against the UDP capacity probe with a verified image md5 and a 150 s soak.

---

## 2026-08-21 — five mechanisms excluded by measuring firmware state during the fault

Switched from A/B statistics to reading firmware bytes while the link is provably pinned. Every
reading below is gated on a verified image md5 and a throughput-confirmed latch.

| byte                       | healthy       | latched | verdict                    |
| -------------------------- | ------------- | ------- | -------------------------- |
| `ctx[0x1bd]` panic flag    | 0             | **0**   | not the cause              |
| `ctx[0xa4]` ladder max     | 15            | **15**  | ladder intact, no collapse |
| `ctx[0xaa]` current index  | ~11-15        | **3**   | index stuck low            |
| `ctx[0x1a9]` probe backoff | 0, 16, 29, 35 | **23**  | inside the healthy range   |
| channel width              | 20M           | 20M     | bandwidth ratchet inert    |

### The soak: it is genuinely pinned, not slow recovery

Every earlier "latch" call used a 5-8 s window, while the bootstrap-at-bottom patch needed ~10 s of
heavy traffic to climb 0 -> 15. So "pinned" and "recovers slower than I measure" had never been
separated. Held continuous saturated traffic for 120 s after a confirmed latch:

    attempt 2: 4.43 Mbps -> LATCHED
    soak +10s .. +120s: 4.10 4.09 4.04 4.14 4.03 4.09 4.09 4.13 3.93 4.10 4.12 4.11 Mbps
    tx bitrate: 6.0 MBit/s throughout

Zero upward movement in two minutes of maximum traffic. That also kills the **attempt gate**: under
saturation the probe rate accumulates attempts far beyond any plausible `cfg[0x25]`.

### Measurement-integrity defects found and fixed

All five produced _confident_ output rather than visible failure, which is why the earlier A/B phase
kept yielding effects that evaporated on the next batch:

- `iw station dump` is a no-op on this FullMAC driver; `iw dev wlan0 link` is what refreshes the
  PEER block. The peek "refresh" was doing nothing.
- An unrefreshed block reads all zeros, making `nss:0` indistinguishable from a real zero.
- `fwload.sh` copied a missing image silently and left stock running, so a peek reported stock rate
  values as if they were peeked bytes.
- A DNS failure produced empty measurements that `awk` parsed into a confident "NO LATCH".
- Flood-ping packet count is RTT-bound (~4 Mbps regardless of link rate) and cannot see the
  collapse. Replaced with a UDP TX-capacity probe: 450 Mbps healthy vs ~4 latched, 75x margin.

A dead-man reboot timer from a killed run also fired and rebooted the box, wiping `/tmp`; images now
live in `~/skw/images/`.

---

## 2026-08-20 (later) — the panic-fallback attribution is **wrong**

Direct measurement kills it. Peeked `ctx[0x1bd]` during a latch confirmed by real TX throughput:

    HEALTHY : 78.28 Mbit/s   nss:0  -> ctx[0x1bd] = 0
    AFTER   :  5.17 Mbit/s   nss:0  -> ctx[0x1bd] = 0

`psr: 100` in both samples, so the readout block was live, not empty. **The flag is clear while the
rate is pinned.** It is not the mechanism.

### What the A/B numbers actually were

Stock 9/16 latched (56%); flag variants 20–33%. That spread is stimulus drift, not effect — one
block had stock at 0/3 while the candidate went 2/3. Every "fix" regressed on the next batch:
`flagveto` went 0/3 → 2/6, the evidence gate 0/4 → 1/5. A candidate at 0/3 against a ~60% baseline
is worth almost nothing, and I treated it as confirmation three times.

### The lesson, for next time

The flag was found by reading code, and the code reading was _correct_ — one write site, one
consumer, forcing the retry slot 24 → 6 Mbit/s. What was never checked is whether the thing actually
happens during the fault. A ten-minute peek refuted twelve hours of A/B.

**Measure the state during the fault before attributing the fault to it.** The peek primitive
existed the whole time and was used on `cfg[0x29]` and `ctx[0xa4]` early on; it should have been
pointed at `ctx[0x1bd]` the moment the flag became the hypothesis.

Still standing: the reproduction and the band finding (2.4 GHz latches, 5 GHz does not, at any
load). Those are measured, not inferred.

---

## 2026-08-20 (late) — SUPERSEDED: "root cause: the panic fallback, not the rate ladder"

Reproduction restored by pinning the band to 2.4 GHz (`SET_NETWORK 0 freq_list`, runtime only).
Stock then latches on demand: 143.3 → 6.0 Mbit/s, flat through post+180 s.

### The mechanism

`FUN_0012c338` re-arms `ctx[0x1bd]` when no rate scored above zero **and** fewer than four rates
cleared the attempt gate (`cmp r0,#3` @0x12c418). `FUN_0012c900` hard-codes 6 Mbit/s on that flag
(`movs r1,#0x30` @0x12c9d8), overriding the ladder.

CPU starvation stalls **host-side** TX-completion processing, so per-rate statistics go missing
while the radio stays healthy — `psr 94`, `tx_failed 0`, RX at HE-MCS 10 the whole time. The
firmware treats absent statistics as a dead link and pins TX at 6 Mbit/s.

### Measured, interleaved with stock in the same window

| run        | pre   | during load | post+180 s |
| ---------- | ----- | ----------- | ---------- |
| stock-1    | 114.7 | → **6.0**   | **6.0**    |
| flagveto-1 | 114.7 | held        | 68.8       |
| stock-2    | 114.7 | → **6.0**   | **6.0**    |
| flagveto-2 | 114.7 | held        | **114.7**  |

Stock 2/2, `flagveto` 0/2 (0/3 including the standalone run).

### Why every earlier candidate failed

They all repaired the climbing machinery — probe scheduling, backoff, ladder composition — while the
rate was being overridden downstream of the ladder entirely. `clamp nop` re-tested against the
reliable stimulus: 6.0 flat through post+180 s, refuted for real this time.

### Fix

`flaggate zeroonly` — `cmp r0,#3` → `cmp r0,#0`, so the fallback arms only when _no_ rate has any
statistics. Keeps the safety net for a genuinely dead link, removes the misfire. One byte. A/B
running.

---

## 2026-08-20 — ascent is healthy; the latch will not reproduce at −32 dBm

### New tool: a deterministic ascent test

Waiting for a latch is not needed to test whether the ladder can climb. Patch the state-0 bootstrap
so every association starts at the **bottom** of the ladder:

    0012c7d6  d8bf      it le            ->  0022  movs r2, #0
    0012c7d8  4a08      lsrle r2, r1, #1 ->  00bf  nop
    0012c7da  85f8aa20  strb.w r2, [r5, #0xaa]      (unchanged, now stores 0)

Image `b6c2c6d3d398`. Healthy rate control must then climb on demand.

| traffic    | climb from ladder index 0       |
| ---------- | ------------------------------- |
| ~100 pkt/s | MCS 10 @ t+5 s, MCS 11 @ t+10 s |
| 1 pkt/s    | MCS 3 → 4 → 6, MCS 11 @ t+50 s  |

**Ascent is healthy** over a 100× range of packet rate, and reaches 600.4 Mbit/s at 80 MHz.

### What that eliminates

Climbing works, so none of these is sufficient to pin the rate:

- attempt gate `cfg[0x25]` — probes clear it even at 1 pkt/s
- probe step `cfg[0x29]` — measured = 1 by peek, not 0
- backoff accumulator @0x12c890 — already refuted 2/2, now also unnecessary as an explanation
- ladder composition — refuted earlier by `force HE`

With `bypass AB` (probe every interval) also refuted, the fault is **not in probe scheduling**.

### Corrections to earlier entries

- Stats wipe is **conditional** — `if (uVar3 != 0x1c) FUN_0013dfae(ctx+0xbc, 0xe0)`. Earlier
  described as unconditional.
- Backoff `ctx[0x1a9]` is **unsigned, bounded at 255** — `ldrb.w`, `cmp r1,#0xff`. Not a signed
  overflow. Defect is narrower: `add r0,r1` accumulates instead of assigning, so the wait passes the
  intended 64 cap and wraps (254+64 → 62); the saturation guard tests the _old_ value.
- `iw` is installed at `/usr/sbin/iw` — "not installed" was a PATH artifact of the non-login shell.
- A 196 → 63 → 117 Mbit/s swing measured with a python TCP bench was a **CPU artifact**, not a
  latch: PHY was MCS 11 throughout. The bench is CPU-bound (600 Mbit/s PHY, ~120 Mbit/s app). Use
  the PHY rate as the latch signal, never app throughput.

### Reproduction failed — this is the blocker

Box now sits at **−32 dBm, psr 100**. No TX failures, so the descent branch never fires.

| stimulus                                                 | result            |
| -------------------------------------------------------- | ----------------- |
| `stress-ng --cpu 4`, WiFi idle, 300 s                    | MCS 11 throughout |
| `--cpu 8 --io 4 --vm 2`, flood-ping TX, load 14.3, 240 s | MCS 11 throughout |

The old recipe depended on a marginal link, not on CPU load alone. Nothing can be validated until
descent can be triggered again.

### New suspect: bandwidth downgrade, not the rate ladder

`FUN_0012c27a` is a **bandwidth** stepper, not a rate-index converter as assumed:

    uVar5 = ctx[0xa6];
    if (uVar5 + 1 < param_3) { ctx[0x1be] = 0; func_0x000c8888(link, bw_cap); }   // restore
    else if (ctx[0x1be] < bw_cap) {
        ctx[0x1be]++; func_0x000c8888(link, bw_cap - ctx[0x1be]);                 // 80->40->20
        param_3 = uVar5;                                                          // clamp index
    }

The downgrade clamps the rate index to `ctx[0xa6]` while narrowing the channel; restore needs an
index above `ctx[0xa6]+1`, which the clamp itself prevents. Would explain a pin with
`psr 92–99, tx_failed: 0` — at 20 MHz nothing fails, so the ladder sees a healthy rate. Not
confirmed: the bootstrap-at-bottom run restored to 80 MHz, so the path is not always one-way.

---

## 2026-08-16 — the latch is **per-TID**, and it is not a degenerate per-STA ladder

Caught a natural latch on arrival and a second one from an automated reproduction loop. Both
measured with `iperf3 --bind-dev wlan0` and interface byte counters as proof — `-B <wifi-ip>` does
**not** force the interface, and every earlier throughput number taken that way is void.

### The decisive measurement

One association, same second, same radio. Only the DSCP marking differs:

| AC  | TID | throughput    |
| --- | --- | ------------- |
| BE  | 0   | **3.53** Mbps |
| BK  | 1   | **3.40** Mbps |
| VI  | 4   | **58.4** Mbps |
| VO  | 6   | **53.1** Mbps |

Reported rate flips with the class, seconds apart — `legacy_rate: 60, legacy` after a BE burst,
`mcs: 11, ieee80211ax` after a VI burst. So rate state is **per-TID**, and only BE/BK are pinned.

This kills the earlier "one-entry ladder" root cause as written: it was scoped per-STA, and a
per-STA degenerate ladder cannot let VI reach MCS 11 while BE sits at 6.

### What else it kills

- **Not RF, TX power or calibration** — VI runs at MCS 11 on the same link, same instant.
- **Not loss-driven and correct** — at the pinned rate `psr: 92–99`, `tx_failed: 0`.
- **Not slow recovery** — 150 s of continuous BE load, psr 92–99 throughout, never one up-probe.
- **Not accumulated probe backoff** — forcing failures with a high rate floor, then releasing it,
  failed to induce the latch 4/4 times.
- **Not any exposed tunable** — MIB 0x51 `up_rate_class_num`/`down_rate_class_num`/retry limits and
  `rcsperate` all swept, no effect.
- **Not clearable by a firmware ladder rebuild** — MIB 0x50 (`rcminrate`) accepted, link never
  dropped, still 6.0 Mbit/s after 16 s of load.

Re-association still clears it: 4.54 → **257–266** Mbps.

### New capability: the driver can read/write firmware memory

`iwpriv`-style private WEXT ioctl `0x8BE1` exposes, beyond the rate knobs:

- `addrval=<addr>,<val>` → MIB 0x96 → firmware does `*(u32*)addr = val`. **Arbitrary write.**
- `rdaddr=<addr>` → read path exists in the driver but firmware acks 0 bytes on this build. Dead.

The write is enough to patch firmware code live, with no image change and no module reload —
`rmmod`/`modprobe` reverts everything.

### The suppression sites

`FUN_0012c740` state 1, disassembled from the loaded image:

```
0012c7fc  ldrb.w r1,[r5,#0xa4]   ; ladder max index
0012c800  cmp    r0,r1
0012c802  beq    0x12c79e        ; (A) best == max  -> return, never probes
0012c804  ldrb.w r0,[r5,#0x1a9]  ; probe backoff
0012c808  cbz    r0,0x12c82e     ;  0 -> enter probe state
0012c810  b      0x12c79e        ; (B) backoff pending -> return
```

Since traffic cannot induce the latch and only association clears it, (A) — `ctx[0xa4]` built wrong
at ladder-build time — is the leading mechanism, with the correction that the build is per-TID. TID
0 is used from the first millisecond of an association; TID 4/6 are used much later, which is
exactly when the capability map has had time to populate.

### Fix candidate, tested live

Patch the aligned word at `0x0012c800`:

| variant | word         | effect                                       |
| ------- | ------------ | -------------------------------------------- |
| orig    | `0xd0cc4288` | `cmp r0,r1 ; beq 0x12c79e`                   |
| A       | `0xbf004288` | `cmp r0,r1 ; nop` — bypass (A), keep backoff |
| AB      | `0xe0144288` | `cmp r0,r1 ; b 0x12c82e` — always probe      |

Variant AB written into a live latched radio: **5.24 → 271/275/268** Mbps, firmware TX
`legacy_rate: 60` → `mcs: 11`. wpa_supplicant logged a locally-generated roam inside the same
window, so the result needed a control.

**Control run, and the result is retracted.** On a _healthy_ link, three writes:

| write                              | association events caused |
| ---------------------------------- | ------------------------- |
| patch word `0xe0144288`            | **1** (bssid …:91 → …:90) |
| no-op, original value `0xd0cc4288` | **1**                     |
| unused DRAM `0x20230000 = 0`       | **1**                     |

**Any `addrval` write costs exactly one re-association.** The write path itself disturbs the chip,
so live patching is unusable as a test method, and the 271 Mbps was the reset, not the patch.

### What that re-reads

`rcminrate` really does rebuild the ladder — forcing a floor while latched produced
`mcs: 5, ieee80211ax`, so a rebuilt ladder **does** contain HE entries. Yet the TID returns to
legacy 6 and never climbs. So the ladder is not degenerate and **(A) is not firing**; the pin is
**(B), the probe backoff** at `ctx[0x1a9]`.

That fits the signed-char overflow already documented: a negative counter still suppresses, and the
`ctx[0x1a9]--` decrement walks it _further_ from zero, so it clears only after ~255 intervals. **The
150 s soak was too short to see it.** Testing with a 12-minute soak.

If it recovers on that timescale, the fix is to clamp the accumulator at 34151 — not to bypass the
suppression at all. Patching must go through the image plus a module reload, since runtime writes
re-associate.

### Reproduction — deterministic, and it names the trigger

Reassociation loops are a bad reproducer: 1 hit in ~19, then 0 in ~130 more. Cold-starting the
firmware, holding a BE flow across the association, and inducing failures with a raised rate floor
all failed too.

The mechanism said what to try instead. `FUN_0012c338` admits a rate as a candidate only once it has
accumulated `cfg[0x25]` attempts:

```c
if ((uint)cfg_min_attempts <= *(uint *)(iVar4 + 0x194))   // attempts >= min
    score = success_pct * rate_table[ladder[i]].mbps;      // only then can it win
```

On a quiet link the probe rate never reaches that count, so **every probe scores as lost** and the
unclamped backoff runs away. So: associate, keep the link quiet, _then_ load it.

**2 for 2, both bands, both arms:**

```
60s idle,    2462 MHz, -10 dBm -> iw 6.0, 4.89 Mbps, legacy_rate: 60
60s trickle, 5200 MHz, -20 dBm -> iw 6.0, 4.19 Mbps, legacy_rate: 60
```

That resolves the apparent randomness. Earlier loops applied load ~7 s after associating — early
enough for probes to succeed. It also explains the rest: the box was found latched after sitting
idle since module load; CPU load "correlated" because it starves the TX path and lowers offered load
during the window; VI/VO are healthy because those TIDs are created later and immediately carry
heavy traffic, so their probes qualify.

Scripts in `tools/`. Detector must require **legacy mode AND** low throughput — throughput alone
false-positives at 8–33 Mbps on post-association settling.

Two harness traps, both self-inflicted: `pkill -f <script>` from an ssh one-liner matches its own
command line and kills the session, and `${2:-}` drops the value of a two-token argument.

### The fix — one instruction, verified against the reproduction

`0x0012c890`, in the backoff accumulator: drop the unclamped `add`.

```
0012c88c  lsl.w  r0,r2,r0   ; r0 = 1<<exp, exp saturates at 6, so <= 64
0012c890  add    r0,r1      ; += backoff  -- unclamped, stored into a signed char
0012c89a  strb.w r0,[r5,#0x1a9]
```

`add r0,r1` → `nop`, so the backoff becomes `1<<exp`: still exponential, capped at 64 intervals,
never accumulating, never wrapping negative. Aligned word `0x29ff4408` → `0x29ffbf00`. Suppression
is kept; unboundedness is not.

Same stimulus, pristine vs patched image, cold start between:

|                               | pristine                  | clamp-patched                     |
| ----------------------------- | ------------------------- | --------------------------------- |
| reps latched at this stimulus | **3 / 3**                 | **0 / 4**                         |
| throughput                    | 4.19 / 4.32 / 4.89 Mbps   | 99.4 / 99.6 / 271 / 277 Mbps      |
| state through 180 s of load   | `legacy_rate: 60`, iw 6.0 | `mcs: 11`, iw 143.3               |
| throughput over that 180 s    | **4.32** Mbps             | **95.5** Mbps                     |
| recovered at                  | **never**                 | first sample, 10 s                |
| health check, immediate load  | —                         | 277 Mbps, psr 100, `tx_failed: 0` |

No regression on a healthy link. Firmware restored to pristine afterwards, md5 matched.

Patching is cheap here because the **CRC is not enforced** and modules reload in place in ~40 s.
`tools/fwpatch.py <img> clamp nop <out>`, then `tools/fw-install.sh`.

**Live patching does not work as a test method** — every `addrval` write costs one re-association,
so patches must go into the image followed by a module reload.

### CORRECTION — that verification is withdrawn, and the trigger is different

The 3/3 vs 0/4 above is **not evidence**. A control run immediately afterwards put the stock image
through the same stimulus 0/6 — the idle-only stimulus had simply stopped reproducing, so the
patched arm's clean sweep meant nothing. The 60 s idle window latched 3/3 inside one ~15 minute
window and then never again.

**The real trigger, from the user:** Wi-Fi **idle** _and_ `stress-ng` running, on **2.4 GHz**.

| ingredient | why                                                                        |
| ---------- | -------------------------------------------------------------------------- |
| Wi-Fi idle | no TX attempts, so no probe can reach `cfg[0x25]` attempts                 |
| CPU load   | TX is a `SCHED_OTHER` workqueue, RX is `SCHED_FIFO` — load starves TX only |
| 2.4 GHz    | latches readily; 5 GHz rarely                                              |

With the band pinned (`wpa_cli set_network 0 freq_list 2462`), stock latches **4/5**. Negative
results worth keeping: CPU load _with_ traffic running does not latch (85–90 Mbps — the traffic
supplies the attempts), and neither does MMC/SDIO IO load (90 Mbps), despite WiFi being SDIO on mmc1
next to rootfs on mmc0.

Re-scored against that stimulus on an 8 s post-load probe: stock **4/5**, patched **2/4**. So the
clamp is **not shown to fix it**.

That probe may be the wrong instrument — the clamp bounds the backoff at 64 intervals rather than
clearing it, so a patched image can read "latched" then recover while a stock one never does.
Time-to-recover under sustained load is what discriminates; `tools/recover2.sh` measures it.

### No firmware patch fixes it

Time-to-recover settled the clamp: patched, 150 s of continuous load, `recovered_at=NEVER` twice,
trace flat at 6.0. Identical to stock.

Two more design lessons before the numbers meant anything:

- **The latch needs the second-or-later reassociation after a firmware boot.** Rep 1 after a reload
  is almost always clean. An interleaved A/B that swaps firmware every rep therefore reloads away
  the very condition being measured — 0/4 on both arms until this was fixed. Compare in
  **alternating blocks**: one install, then several reps on it.
- **Score on throughput, not `iw`.** The rate must be sampled after traffic; on a quiet link `iw`
  reports the last frame sent, so reps read `143.3` while carrying 4.4 Mbps.

Alternating blocks of 4, band pinned, scored on throughput:

| variant      | word         | latched               |
| ------------ | ------------ | --------------------- |
| stock        | —            | **5 / 8**             |
| `bypass AB`  | `0xe0144288` | **2 / 8**             |
| `clamp zero` | `0x29ff2000` | 3 / 4                 |
| `clamp nop`  | `0x29ffbf00` | 2 / 2, never recovers |

`bypass AB` halves it and both its failures were rep 4 of a block, so it delays rather than
prevents. Neither suppression path is the pin.

**Remaining candidate:** the candidate-selector deadlock. `FUN_0012c338` only scores rates that
already have `cfg[0x25]` attempts, so once the ladder is at the bottom no higher rate can ever
accumulate attempts and nothing can score better. Bypassing the probe gate cannot help if the probe
rate is never actually transmitted.

### Also learned: not every byte is patchable

Two images differing by 5 bytes behave differently — which incidentally proves patches do reach the
chip:

| image                                              | result                                             |
| -------------------------------------------------- | -------------------------------------------------- |
| clamp, 2 bytes @ `0x2c890`                         | boots, runs                                        |
| clamp + version string `trunk`→`TRUNK` @ `0x14f20` | **fails to boot twice**, `skw_boot_loader ret=-62` |
| clamp again                                        | boots, runs                                        |

So "the CRC is not enforced" was too broad. Test that the chip boots after any new patch site.

### Root cause found: the capability map is refreshed only once

Two questions from the user forced this open. First — is the recovery just a 2.4→5 GHz move? No:
band pinned, `bssid=<redacted-bssid> freq=2462` identical either side, **4.89 → 102 Mbps**.

Second — can part of re-association be invoked while keeping the link? Yes, and the answer explains
the bug. `rc_init` calls the ROM routine that populates the per-STA capability map **only on the
first init**:

```
0012d67c  cbz  r0,0x12d68c     ; state == 0 -> ROM populate path
0012d684  strb r0,[lr,#0x1b4]  ; else: state = 0
0012d68a  b    0x12d6b0        ; ...and branch past the ROM call
0012d68c  ldrb cfg[0x2d] ; bl 0xc8c48
```

Every later rebuild resets the state but re-derives the ladder from a map it never refreshes. With a
stale map, HE/VHT/HT admission fails; the builder already deletes every OFDM rate except 6 Mbit/s
whenever the peer advertises HT/VHT/HE; so one entry survives, `ctx[0xa4]` becomes 0, and case 0's
"recovery" jumps to index 0 — 6 Mbit/s. Only a fresh context escapes, which is why re-association is
the only thing that works.

Corroboration:

- **`ofdm` variant** (never delete OFDM rates) moved the pinned rate **6.0 → 9.0 Mbit/s**, twice,
  without changing the latch rate (stock 2/8, ofdm 2/8). Ladder composition sets the pinned rung.
- On stock, MIB 0x50 fired against a live latch with **0 association events** — the link never
  dropped — and left it at 6.0 / 5.42 Mbps. So the vendor rebuild really is the non-disruptive slice
  of re-association; it just skips the capability refresh.

**`recap` patch** — `0x0012d688`, retarget the branch to `0x12d68c` so a rebuild resets the state
_and_ refreshes capabilities. Two bytes, `0xe0114677` → `0xe7ff4677`.

|                                   | stock          | `recap`       |
| --------------------------------- | -------------- | ------------- |
| latched, same stimulus and window | attempt 2 of 6 | **0 / 6**     |
| throughput                        | 4.89 Mbps      | 96.8–104 Mbps |

Healthy-link throughput unchanged. Needs more reps — the stimulus reproduces in bursts, so a window
where the stock arm stays clean proves nothing.

### Blocked: the reproduction needs the control path off the radio

The box rebooted (2026-08-16 ~19:56) and came up **without `end0`** — the DTB's ethernet node no
longer probes:

```
rk_gmac-dwmac ffbd0000.ethernet: IRQ eth_lpi not found
rk_gmac-dwmac ffbd0000.ethernet: Not all RX queues were configured
probe of ffbd0000.ethernet failed with error -22
```

Every daemon and ssh then moved onto `wlan0`, and the same stimulus that had been latching 3-4 in 8
went **0/5**. Measured background load on an "idle" `wlan0`: **264 tx packets / 52 KB per 60 s**.
That is enough to keep supplying TX attempts, so no probe is ever scored as lost and the latch
cannot form.

Quieting the radio (stopping `systemd-resolved` + `systemd-timesyncd`, 201 → 28 packets/60 s) was
**not sufficient**. With the band pinned, `stress-ng` on all cores and Wi-Fi idle, stock went
**0/20**.

The reason showed up in the signal: **0/+1 dBm**, against **−9…−12 dBm** for every run that ever
reproduced. The box has been moved much closer to the AP. So position is a live variable, and a very
strong signal _suppresses_ the bug — which also kills the earlier "too close, receiver saturation"
idea.

So the `recap` fix **cannot be confirmed** in the box's current position. To resume:

1. Put the box back roughly where it was — target ~−10 dBm on 2.4 GHz, not touching the AP.
2. Restore `end0` (DTB node fails to probe) so the control path is off the radio under test.
3. Re-run `~art/skw/hunt.sh` — it hunts for a burst on stock and, on the first latch, runs the
   stock/recap alternation automatically.

`/tmp` was wiped by the reboot; scripts and images now live in `~art/skw/`.

### Why it stopped reproducing: the DTB changed under the test

Not box position, and not a hidden workaround — both were checked and cleared:

- **No workaround running.** No wifi/rate/latch systemd unit or timer, `/usr/local/sbin` holds only
  `fw-restore`, cron is stock Armbian, firmware md5 is stock, and the box logged **0 spontaneous
  re-associations** over 16 idle minutes.
- **Not load pattern.** `stress-ng` with Wi-Fi idle, with traffic, on 2.4 GHz and 5 GHz, daemons up
  and down — all clean (65-271 Mbps, `mcs: 11`).

The active device tree `rk3518-h96max-zx.dtb` was **rewritten at 20:25**, with no dpkg activity that
day; every other DTB in `/boot` still carries the 00:05 package timestamp. `../rk35xx-tvbox-armbian`
has matching fresh commits (`Update dts in overlay version`,
`Add h96 max dts for upstream submission`). The same change also broke ethernet —
`ffbd0000.ethernet` now fails to probe with `IRQ eth_lpi not found` /
`Not all RX queues were configured` / `-22`.

All reproducing runs were on the old DTB; nothing has reproduced on the new one. To resume
reproduction, restore the device tree that was in place that afternoon.

### Also shipped: watchdog

`seekwave-latch-watchdog.sh` — legacy TX rate ≤6 Mbit/s at strong signal, confirmed over two samples
10 s apart, then re-associate. Verified against a live latch: **5.24 → 98.7 Mbps**. `install/` has
the unit and timer, plus a udev rule and installer for the firmware patch for anyone wanting to
experiment. DSCP VI remains the zero-service alternative.

---

## 2026-08-11 — the real bug: FullMAC firmware latches TX rate at 6 Mbps

**Dual 4K streaming works: 21.75 fps per camera, 58 Mbps total, PHY steady at 600.4 Mbps, load
0.30.** Every earlier failure in this session was downstream of one thing.

### The bug

The SV6621S is **FullMAC** — TX rate control lives in chip firmware, not mac80211. It latches at the
**6.0 Mbps basic rate** and stays there:

- idle does not clear it — 45 s of quiet, still 6.0 Mbps
- `iw set bitrates` is rejected (`Operation not supported`) because there is no host rate control
- only **re-association** recovers it: `systemctl restart netplan-wpa-wlan0.service` → 600.4 Mbps in
  ~8 s

While latched: **all four cores 93–98% idle**, sys 1–5%, softirq ~0%. Nothing is starved; the radio
is simply transmitting at the lowest rate it has.

### Everything the latch faked

| Claim I made                               | Reality                                                                                 |
| ------------------------------------------ | --------------------------------------------------------------------------------------- |
| "dual 4K starves the WiFi"                 | 264 Mbps idle vs **257 Mbps with dual 4K capture running** — no interference            |
| "concurrent capture ceiling is 38–62 Mbps" | no such ceiling                                                                         |
| "CPU-coupled WiFi, keep the box idle"      | the original compile-load collapse was almost certainly this same latch, not contention |

The first session's "WiFi TX is 5.5 Mbps" was the same thing. I diagnosed CPU coupling because load
correlated once; the actual mechanism is a firmware latch that a heavy-load episode can trigger and
that then persists indefinitely.

### Tried and ruled out

IRQ affinity (every IRQ defaults to CPU0; moved xhci→CPU1, ehci→CPU2 — zero effect) · `skw-gpio-irq`
cannot be re-affined, GPIO-cascaded, returns `I/O error` · driver kthreads ignore `taskset`
(`PF_NO_SETAFFINITY`) and `skwifid_dywq` workers are per-CPU · rate masks unsupported. None of it
mattered, because none of it was the cause.

**Patching the kernel module cannot fix this** — the broken logic is in firmware.

### Fix, installed

`wifi-rate-watchdog` (`/usr/local/sbin/` + systemd timer, 30 s) — if `tx bitrate` < 100 Mbps while
associated, re-associate; 300 s cooldown to prevent flapping. Enabled and active.

### Harness artifacts along the way

Missing `ffmpeg -nostdin` (backgrounded ffmpegs fight over stdin →
`VIDIOC_QBUF: Bad file descriptor`) · ffmpeg's `tcp://` output ~9× slower than a plain socket (4.3
vs 38.5 Mbps) · `bench/send_probe.py`'s quadratic buffer scan, fine at 50 KB frames, not at 170 KB.

**Method lesson: check the PHY rate before trusting any throughput measurement on this box.** Three
wrong conclusions came from measuring while the radio was silently latched.
