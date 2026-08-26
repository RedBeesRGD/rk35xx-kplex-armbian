# Patch/verify loop — what was established on hardware

H96 Max, 2026-08-16. Peer `192.168.1.211`. Every throughput figure below is
`iperf3 --bind-dev wlan0` with `/sys/class/net/*/statistics/tx_bytes` deltas quoted as proof.

## Measurement discipline

`iperf3 -B <wifi-ip>` does **not** force traffic onto `wlan0`. Proven by counters — `wlan0 tx
delta: 0 MB`, `end0 tx delta: 92 MB`, and `ip route get … from 192.168.1.217` → `dev end0`. The box
has ethernet in the closet, so anything measured that way went over the wire.

**All conclusions in the previous revision of this file that rested on a `-B` measurement are
void**, including "the one-entry ladder is not the mechanism, because throughput stayed 94.9
Mbit/s". That number was ethernet.

## Infrastructure (works)

- **Firmware reloads in place, no reboot** — `rmmod swt6621s_wifi skwbt; rmmod skw_sdio_lite;
  modprobe skw_sdio_lite; modprobe swt6621s_wifi`, ~40 s including re-association. `wlan0` is
  managed by `netplan-wpa-wlan0.service`; stop it first, start it after.
- **The loaded image is board-specific** — `SWT6621S_IRAM_SDIO.h96max-zx,rk3518-tvbox.bin`, in
  `/lib/firmware` *and* `/lib/firmware/seekwave`.
- **Most bytes are freely patchable, not all.** `0x2c890` and `0x57ea2` tolerate edits; `0x14f20`
  makes the chip fail to boot. See below.
- Recovery net: `/root/fw-backup`, `/usr/local/sbin/fw-restore`, `fw-guard.service`.
- **Live firmware state**: `/proc/skwifid/chip1.sdio/wlan0` prints per-peer TX mode, rate, `psr`,
  `tx_failed`, per-AC queue depths. This is the single most useful diagnostic on the box.

## Ground truth — a natural latch

Found latched on arrival, firmware byte-identical to backup:

| | |
|---|---|
| wlan0 tx / end0 tx | 4 MB / **0 MB** |
| throughput | **5.24** Mbps |
| reported tx bitrate | 6.0 MBit/s |
| rx bitrate | 129–143 MBit/s HE-MCS 10/11 |
| signal | −9 … −11 dBm |
| firmware TX line | `legacy_rate: 60, nss:1, legacy, psr: 98, tx_failed: 0` |

## The decisive experiment — it is per-TID

One association, same second, only DSCP differing:

| AC | TID | throughput | reported after a burst of that class |
|---|---|---|---|
| BE | 0 | **3.53** Mbps | `legacy_rate: 60, legacy` / iw 6.0 |
| BK | 1 | **3.40** Mbps | — |
| VI | 4 | **58.4** Mbps | `mcs: 11, ieee80211ax` / iw 143.3 |
| VO | 6 | **53.1** Mbps | `mcs: 9, ieee80211ax` / iw 114.7 |

Repeatable: BE 5.45 then VI 44.2 immediately after, then BE 6.0 again. Alternating BE/VI/BE/VO
bursts flip the reported rate every time.

## Negative results, each one useful

| Attempt | Result |
|---|---|
| MIB 0x50 `rcminrate` rebuild, then 16 s load | still 6.0, link never dropped |
| Raising the rate floor to 0x34 / 0x37 | throughput *fell* to 0.0–0.7 Mbps; floor does take effect |
| 150 s continuous BE soak, psr 92–99 | never one up-probe |
| MIB 0x51 `up_rate_class_num` = 2 / 4 / 8 | no change |
| MIB 0x51 `down_rate_class_num` = 0 / 3 / 8 | no change |
| `rcsperate` = 1 / 2 / 4 | rejected, "value not support" |
| Force failures at a high floor, then release, ×4 | never induced the latch |
| `rdaddr=<addr>` firmware memory read | firmware acks 0 bytes; unusable on this build |

`wpa_cli reassociate` recovers: **4.54 → 257–266** Mbps, wlan0 counters 200–209 MB, end0 0 MB.

## Reproduction

**2.4 GHz, `stress-ng` running, Wi-Fi idle during the load, measure after it stops.**
`tools/idlestress-repro.sh`. Stock latches 4/5 with the band pinned.

| ingredient | why |
|---|---|
| Wi-Fi idle | no TX attempts, so no probe can reach `cfg[0x25]` attempts |
| CPU load | TX is a `SCHED_OTHER` workqueue, RX is `SCHED_FIFO` — load starves TX only |
| 2.4 GHz | **reinstated 2026-08-20** — same stimulus, same hour: 5 GHz 0/2, 2.4 GHz 1/1 (see below) |
| 2nd+ association since boot | rep 1 after a firmware reload is almost always clean |
| control path off the radio | with ssh and daemons on `wlan0` the link is never quiet — same stimulus went 0/5 |

```sh
wpa_cli -i wlan0 set_network 0 freq_list 2462
```

Idle alone (no CPU load) also works but less reliably — it latched 3/3 in one 15-minute window and
0/6 shortly afterwards, which is what made the first fix comparison worthless.

### 2026-08-20 — the band is the variable, not the CPU load

Same box, same hour, same `stress-ng --cpu 4` with Wi-Fi idle. Band pinned at runtime through the
wpa control socket (`SET_NETWORK 0 freq_list`), never written to disk.

| band | signal | stimulus | result |
|---|---|---|---|
| 5 GHz / 80 MHz | −32 dBm | `--cpu 4`, 300 s | MCS 11 throughout |
| 5 GHz / 80 MHz | −32 dBm | `--cpu 8 --io 4 --vm 2` + flood-ping TX, load 14.3, 240 s | MCS 11 throughout |
| 2.4 GHz / 20 MHz | −23 dBm | `--cpu 4`, 300 s | **143.3 → 8.6 → 6.0, no recovery** |

    pre:        143.3 MBit/s HE-MCS 11
    load+30s:     8.6 MBit/s HE-MCS 0
    load+60s:     6.0 MBit/s            (one blip to 8.6 at +120s, else flat)
    --- load off ---
    post+30s:     6.0 MBit/s

Signal is *stronger* on 2.4 GHz here (−23 vs −32 dBm), so this is not a link-margin effect. No
amount of CPU or IO load reproduces it on 5 GHz; the ordinary recipe reproduces it on 2.4 GHz in
under 30 s. Earlier non-reproduction was a band artifact, not a fix and not the DTB.

Latched state, measured: `connect width: 20M` both healthy and latched — so `FUN_0012c27a`'s
bandwidth stepper is inert here (`bw_cap == 0` short-circuits it at the first `cbz`), and a
bandwidth ratchet cannot be the mechanism. RX stays healthy at HE-MCS 10 / 129 Mbit/s; only TX
is pinned, reporting `psr: 94, tx_failed: 0`.

### Re-tests against the reliable reproduction

Every earlier verdict was scored against a stimulus whose own control ran 0/6, which the notes
already admit made those comparisons worthless. Re-run with `tools/../skw/fixtest.sh` — stock
control latches 1/1 in the same window.

| patch | pre | during load | after load (180 s) | verdict |
|---|---|---|---|---|
| stock control | 143.3 | → 8.6 → 6.0 | 6.0 flat | latches |
| `clamp nop` | 114.7 | MCS 9 at +30 s, 6.0 from +60 s | **6.0 flat** | refuted |

Bounding the probe backoff delays the collapse by one sample and changes nothing after. Consistent
with ascent being healthy already (see WORKLOG 2026-08-20): patches that repair the climbing
machinery cannot help if the ladder has one rung left to climb.

### Root cause: the panic fallback misfires

`FUN_0012c338` clears `ctx[0x1bd]` on entry, then re-arms it when no rate scored above zero **and**
fewer than four rates cleared the attempt gate:

    0012c412  uxtb.w r0,r8       ; r0 = count of rates with statistics
    0012c418  cmp    r0,#3
    0012c41c  movls  r0,#1
    0012c41e  strbls.w r0,[r6,#0x1bd]

`FUN_0012c900` then hard-codes 6 Mbit/s on that flag (`0012c9d8 movs r1,#0x30`), overriding the
ladder outright. Under CPU starvation the statistics are missing because the **host** could not
process TX completions — the radio is fine throughout (`psr 94`, `tx_failed 0`, RX at HE-MCS 10).
The firmware reads "almost no rate statistics" as "this link is terrible".

Interleaved A/B, stock alternating with `flagveto`, same window:

| run | pre | during load | post+180 s |
|---|---|---|---|
| stock-1 | 114.7 | → **6.0** | **6.0** |
| flagveto-1 | 114.7 | 114.7 held | 68.8 (MCS 5) |
| stock-2 | 114.7 | → **6.0** | **6.0** |
| flagveto-2 | 114.7 | 114.7 held | **114.7** |

Stock 2/2 latched, `flagveto` 0/2 (0/3 with the earlier standalone run).

This explains what never fitted: the pinned rate reports excellent success because the rate ladder
is not what pins it; the latch is per-TID because the flag is per-context; ascent tests pass
because ascent was never broken; and every ladder-side patch failed because the ladder was never
holding the rate down. `ofdm keep` moved the pin 6.0 → 9.0 by changing which rate the *chain*
fell back to, not by fixing any ladder.

**Preferred fix** is `flaggate zeroonly` (`cmp r0,#3` → `cmp r0,#0`): arm the fallback only when
*no* rate has any data, which is genuinely degenerate. A fallback for a dead link is reasonable;
"fewer than four rates have statistics" is not a proxy for one — it is the normal state of a quiet
link. One byte, keeps the safety net, drops the misfire.

### The ladder-collapse reading (superseded)

`ofdm keep` was filed as a refutation because it stayed pinned — but it pinned at **9.0** instead
of 6.0. That is not a refutation, it is the signature of a degenerate ladder: the patch changed
*which* single entry survived without preventing the collapse. With
`probe = min(current + cfg[0x29], ctx[0xa4])` and `cfg[0x29] = 1` (measured), a ladder whose max
index has collapsed to the current index makes every probe a no-op — which is exactly why
`bypass AB` (probe every interval) also failed.

`ctx[0xa4] = 15` measured healthy. The latched value is the deciding measurement.

**Does not reproduce it:** CPU load *with* traffic running (85–90 Mbps — the traffic supplies the
attempts); MMC/SDIO IO load (90 Mbps); reassociation loops (1 hit in ~19, then 0 in ~130); firmware
cold starts (0 in ~40); a BE flow held across association (0 in 12); induced failures at a raised
rate floor (0 in 4).

Score on **throughput**, not `iw` — sampled before traffic it reports the last frame sent, so reps
read `143.3` while carrying 4.4 Mbps.

## Firmware patches at the suppression sites — none fixes it

Alternating blocks of 4 reps, one install per block, band pinned, scored on throughput
(`<40 Mbps`). Two design rules had to be learned first, and both silently produced null results:

- **Latches need the second-or-later reassociation after a firmware boot.** Rep 1 after a reload is
  almost always clean, so an A/B that swaps firmware every rep reloads away the condition being
  measured — 0/4 on both arms until switched to blocks.
- **Score on throughput.** `iw` sampled before traffic reports the last frame sent, so reps read
  `143.3` while carrying 4.4 Mbps.

| variant | word | latched |
|---|---|---|
| stock | — | **5 / 8** |
| `bypass AB` @`0x0012c800` | `0xe0144288` | **2 / 8** |
| `clamp zero` @`0x0012c890` | `0x29ff2000` | 3 / 4 |
| `clamp nop` @`0x0012c890` | `0x29ffbf00` | 2 / 2, `recovered_at=NEVER` in 150 s |

**An earlier run read 3/3 stock vs 0/4 patched and is withdrawn** — its stock arm ran in a window
where the stimulus was not reproducing at all (0/6 in a control immediately afterwards).

Neither suppression path is the pin. Remaining candidate: `FUN_0012c338` only scores rates that
already have `cfg[0x25]` attempts, so once the ladder is at the bottom no higher rate can
accumulate attempts and nothing can score better.

No regression on a healthy link for any variant: 97–277 Mbps under immediate load. Firmware
restored to pristine after each run; md5 matched the backup.

## The stimulus matrix, exhausted on the new device tree

After the device tree was rewritten (20:25), **nothing reproduces**. Everything below is zero
latches, ~50 cycles, all landing at `mcs: 11`:

| axis | values tried |
|---|---|
| window | 60 s, 90 s, **300 s**, **1200 s** |
| stimulus | idle (no traffic), TX-loaded, **RX-loaded** (576 MB / 1759 MB in vs 3-5 MB out) |
| band | 2462 and 5200, both pinned |
| stress | `--cpu 4` and `--cpu 8` |
| radio noise | daemons up (201 pkt/60 s) and stopped (28) |

Against 3-4 latches in 8 cycles on the old device tree the same afternoon. Throughput does sag
under long load (90 → 67 Mbps) but the rate never drops off `mcs: 11`.

Two variables changed together and neither is eliminated: the **device tree** (rewritten at 20:25,
hand-installed, no dpkg activity; it also broke `end0`) and **position** (−9…−12 dBm when it
reproduced, −26/−30 dBm now; 0 dBm in between also gave 0/20).

Putting the box back in the closet separates them: that restores −10 dBm while keeping the new
device tree.

## 2026-08-18: all five candidate patches refuted against a live reproduction

The user induced the latch incidentally during thermal validation (`stress-ng --cpu 4 -t 300` on an
idle 2.4 GHz link) — a fifth spontaneous occurrence, and it survives the rebuilt 26.8.1 image. That
gave a hot window, so every variant was finally tested with a control that was actually latching.

| firmware | site | result |
|---|---|---|
| stock | — | **LATCHED 3/3**, 6.0 Mbit/s |
| `recap` | `0x2d68a` | LATCHED 6.0 |
| `bypass AB` | `0x2c802` | LATCHED 6.0 |
| `clamp zero` | `0x2c890` | LATCHED 6.0 |
| `clamp nop` | `0x2c890` | LATCHED, never recovers |
| `ofdm keep` | `0x2d38c` | LATCHED **9.0** (1 of 2) |

Reassociation recovers every time: 6.0 → 143.3 Mbit/s, `mcs: 11`.

**MIB 0x50 does not recover it on either stock or `recap`** — accepted, 0 association events, still
6.0. So the rebuild genuinely runs without dropping the link, and refreshing the capability map is
not what association does that matters.

What this rules out, with a latching control:

- the probe backoff (cleared, bounded — no effect)
- both probe-suppression branches in the tick (bypassed — no effect)
- the capability-map refresh on rebuild (forced — no effect)

`ofdm keep` only moves the pinned rung 6.0 → 9.0, twice now. So the ladder's *contents* set which
rate it pins to, but something else does the pinning, and it is not in the tick state machine.

No candidate patch fixes the latch. The mechanism is still open.

## 2026-08-18 later: ladder composition is NOT the mechanism either

Two admission patches were added and both refuted, and one of them settles the question:

| variant | site | HE admitted | outcome |
|---|---|---|---|
| `force HE` (`movs r0,#0`) | `0x2d52a` | MCS 0-7 | ok, ok, **LATCHED 6.0** |
| `and #2` (`and r0,r0,#2`) | `0x2d52a` | MCS 0-11 | MCS 0 collapse, **LATCHED 6.0** |

`force HE` ran at 86.0 Mbit/s (`mcs: 7`) before the stimulus, proving HE entries were in the ladder
— and it still fell to **legacy 6.0**. So the ladder holds good rates and the firmware selects the
worst one anyway.

**That kills the one-entry-ladder theory.** It is not ladder composition, not the probe backoff,
not either suppression branch, and not the capability refresh. The `ctx[0x16]` HE map is also not
the gate: forcing it to a valid value (2 = MCS 0-11) still latched.

What the ladder *does* control is which rung it pins to when it has no HE: stock 6.0, `ofdm keep`
9.0. So composition selects the victim, something else does the pinning.

Still standing, untested: the candidate selector `FUN_0012c338` and its `cfg[0x25]` attempt gate,
and the ROM rate-LUT programming (`func_0x000c8f92`) — neither reachable by the patches tried.

Controls: stock latched 3 of 4 across this window; the one stock miss was at 23:01.

Re-association recovers **on the same channel and BSSID** — band pinned, `bssid=<redacted-bssid>
freq=2462` either side, 4.89 -> 102 Mbps. Not a band steer.

What association does that a rebuild does not: `rc_init` calls the ROM routine that populates the
per-STA capability map only on the **first** init.

```
0012d67c  cbz  r0,0x12d68c     ; state == 0 -> ROM populate path
0012d684  strb r0,[lr,#0x1b4]  ; else: state = 0
0012d68a  b    0x12d6b0        ; ...and branch past the ROM call
0012d68c  ldrb cfg[0x2d] ; bl 0xc8c48
```

Later rebuilds re-derive the ladder from a map they never refresh. With a stale map HE/VHT/HT
admission fails, the builder deletes every OFDM rate except 6 Mbit/s (it does that whenever the
peer advertises HT/VHT/HE), `ctx[0xa4]` becomes 0, and case 0's recovery jumps to index 0 = 6
Mbit/s. Only a fresh context escapes.

Two supporting measurements:

- `ofdm` variant (never delete OFDM rates) moved the pinned rate **6.0 -> 9.0 Mbit/s**, twice,
  without changing how often it latches (stock 2/8, ofdm 2/8). The ladder composition determines
  what it pins to.
- On stock, MIB 0x50 rebuild fired against a live latch with **0 association events** — the link
  never dropped — and left it at 6.0 / 5.42 Mbps.

`tools/fwpatch.py <img> recap always <out>` retargets `0x0012d688` to `0x12d68c`, so a rebuild
resets the state *and* refreshes capabilities.

| | stock | `recap` |
|---|---|---|
| latched, same stimulus and window | attempt 2 of 6 | **0 / 6** |
| throughput | 4.89 Mbps | 96.8-104 Mbps |

## The probe step: a one-way ratchet, derived from code

The chain rate is `ctx[0xaa]` (current index) in every state except **state 2 (probe)**, where:

```c
uVar13 = ctx[0xaa];
if (ctx[0x1b4] == 2) {                            // probe state
    uVar13 = cfg[0x29] + uVar13;                  // probe index = current + step
    if (ctx[0xa4] < uVar13) uVar13 = ctx[0xa4];   // clamp to ladder max
    ctx[0xab] = uVar13;                           // -> the TX chain's rate
```

**If `cfg[0x29]` is 0 the probe transmits at the rate already in use.** Combined with the selector
wiping all 28 per-rate stats at the end of every run (`FUN_0013dfae(ctx + 0xbc, 0xe0)`), only the
rate actually transmitted during an interval can ever be a candidate. The ladder descends freely and
can never ascend — a one-way ratchet with no exit.

That accounts for every refuted patch:

| patch | why it could not work |
|---|---|
| `force HE`, `and #2`, `ofdm keep`, `recap` | changed ladder *contents*; probing still sampled the current rate |
| `bypass AB` | forced the probe to fire, but it probes `current + 0` |
| `clamp zero`, `clamp nop` | backoff is irrelevant when the probe goes nowhere |
| attempt-gate removal | let zero-score rates win instead — dropped to 1.0 Mbit/s |
| flag-veto (`ctx[0x1bd]`) | that flag picks a chain *slot*, not the ratchet |

**`cfg[0x29]` is settable at runtime** — `rcratechg` byte 2, no patch required. First test, stock
firmware with `cfg[0x29]=3` set before the stimulus: **no latch**, 129.0 Mbit/s `mcs: 10`.

Caveats: n=1 pending an alternation with byte-identical firmware in both arms; the default value
cannot be read back (`rdaddr` is dead on this build) so "it is 0" is inference; and `rcratechg`
overwrites four neighbouring config bytes, so a clean fix would set only that one.

## Not every byte is patchable

| image | result |
|---|---|
| clamp, 2 bytes @ `0x2c890` | boots, runs |
| clamp + `trunk`→`TRUNK` @ `0x14f20` | **fails to boot twice**, `skw_boot_loader ret=-62` |
| clamp again | boots, runs |

Which also proves patches reach the chip. "The CRC is not enforced" was too broad — verify the chip
boots after any new patch site.

## Blocked: reproduction needs the control path off the radio

After a reboot the box came up without `end0` — the DTB ethernet node no longer probes
(`IRQ eth_lpi not found`, `Not all RX queues were configured`, `-22`). ssh and every daemon moved
onto `wlan0`, and the same stimulus went **0/5**.

Measured background load on `wlan0`, 60 s samples:

| condition | tx packets |
|---|---|
| idle, no ssh at all | **201** |
| idle, `systemd-resolved` + `systemd-timesyncd` stopped | **38** |

201 packets (3.4/s) is enough to keep supplying TX attempts, so no probe is scored as lost and the
latch cannot form. Silencing the two network talkers gets it to 0.6/s, close to the near-silent
radio the original reproductions had with management traffic on ethernet — enough to try again.

Quieting the radio was not enough. At 28 packets/60 s, band pinned to 2462, `stress-ng` on all
cores with Wi-Fi idle, stock went **0/20**. Signal had meanwhile changed to **0/+1 dBm**, against
−9…−12 dBm for every run that reproduced — the box was moved much closer to the AP. So position is
a live variable, and a very strong signal suppresses the bug.

`/tmp` was wiped by the reboot; scripts and images now live in `~art/skw/`.

## Watchdog — verified

`seekwave-latch-watchdog.sh`, against a live latch:

```
latched          5.24 Mbps   iw=6.0     legacy_rate: 60, psr: 99, tx_failed: 0
after watchdog  98.7  Mbps   iw=143.3   mcs: 11, ieee80211ax
```

## Fix candidate, applied to a live latched radio

Aligned word at `0x0012c800`, variant `AB` (`0xd0cc4288` → `0xe0144288`, `beq` → `b 0x12c82e`),
written with `addrval` — no image change, no module reload:

| | before | after |
|---|---|---|
| BE throughput | 5.24 Mbps | **271 / 275 / 268** Mbps |
| firmware TX | `legacy_rate: 60, legacy` | `mcs: 11, ieee80211ax` |
| reported | 6.0 MBit/s | 600.4 MBit/s |

**RETRACTED.** Control on a *healthy* link, three writes, association events counted:

| write | association events caused |
|---|---|
| patch word `0xe0144288` | **1** |
| no-op — original value `0xd0cc4288` | **1** |
| unused DRAM `0x20230000 = 0` | **1** |

Every `addrval` write costs exactly one re-association, including a write that changes nothing.
The write path disturbs the chip, so the 271 Mbps was the reset. **Live patching cannot be used to
test a fix.** Patches must go into the image, followed by a module reload.

## Re-reading the mechanism

`rcminrate` genuinely rebuilds the ladder — forcing a floor while latched produced `mcs: 5,
ieee80211ax`, so a rebuilt ladder contains HE entries. The TID still falls back to legacy 6 and
never climbs.

So the ladder is **not** degenerate and `ctx[0xa4]` is fine, which pointed at **(B)**, the probe
backoff at `ctx[0x1a9]`.

**That was wrong too.** Patching (B) three ways changed nothing — see above. Neither suppression
path is the pin, and the remaining candidate is candidate selection itself: `FUN_0012c338` only
scores rates that already have `cfg[0x25]` attempts, so once the ladder is at the bottom no higher
rate can ever accumulate attempts and nothing can score better. Removing a probe gate cannot help
if the probe rate is never actually transmitted.

## Next

1. Confirm `recap` over more reps — the stimulus reproduces in bursts, so a window where the stock
   arm does not latch proves nothing about the patched arm.
2. With `recap` loaded, catch a latch (if one still occurs) and check whether MIB 0x50 now recovers
   it. That would turn the vendor command into a supported non-disruptive fix.
3. Find why the capability map goes stale in the first place — `func_0x000c8c48` is ROM, so this
   needs runtime observation rather than static analysis.
