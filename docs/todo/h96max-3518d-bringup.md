# H96 Max 3518D — what is still open

The box runs Armbian, boots in 13.6 s and is reachable over SSH; `docs/h96max-3518d/board.md` holds
the test report and the measured numbers, and the worklog holds how each was arrived at. This file
is only what remains.

## What this box is for

A **portable player**: HDMI into whatever screen is to hand, powered over USB, playing from the
internet (YouTube), from a USB stick, and ideally receiving a stream pushed from a phone. That goal
decides what still matters, and most of it is already measured:

| Need                   | State                                                                  |
| ---------------------- | ---------------------------------------------------------------------- |
| YouTube's codec (VP9)  | ✅ hardware, 364 fps @1080p — enormous headroom                        |
| H.264 / HEVC           | ✅ hardware                                                            |
| **AV1**                | ➖ no hardware. Software `dav1d` gives **40.6 fps @1080p**, 65.9 @720p |
| Wi-Fi for 4K streaming | ✅ 185–206 Mbit/s; 4K needs ~25                                        |
| USB stick playback     | ✅ 35 MB/s = 280 Mbit/s, far above any bitrate                         |
| Sustained load         | ✅ no throttling, 27 °C headroom                                       |
| Remote                 | ✅ BLE, once paired and trusted                                        |
| **HDMI output**        | ✅ picture confirmed — console renders. Modes, audio and CEC untested  |

**Pin players to VP9.** The AV1 figure is a synthetic low-complexity clip with all four cores pegged
and nothing left for rendering or UI; real grainy AV1 will be worse, and 1080p60 or 4K AV1 is out of
reach. YouTube serves VP9 to anything that does not advertise AV1, so this is a client setting, not
a hardware limit to design around.

**The brownout matters more for this use case than any other.** Plugging a USB stick into a running
box resets it — so the stick has to be in _before_ power, or on a powered hub. For a device whose
whole point is "plug a stick in and watch", that is a real usability constraint, not a footnote.

**Prefer a native player to a browser.** 2 GB of RAM makes Chromium a poor bet; Kodi or mpv with
`rkmpp` gets hardware decode, a BLE-remote-friendly UI, USB browsing, and a built-in UPnP renderer
for pushing a stream from a phone. Chromecast reception is proprietary and not on the table; DLNA/
UPnP is.

## Needs hands on the box — batch into one sitting

Nothing outstanding. The three that remained were closed as decisions, not measurements:

- **USB hot-plug brownout** — accepted. The 5 V rail cannot absorb a device being inserted live; no
  board config changes it, and there is no software fix. Ports work for devices present at boot.
- **DCI 4K (4096x2160)** — skipped deliberately. The panel-native `3840x2160p60` works, DCI is a
  cinema mode nothing here needs, and `docs/hdmi-edid-override.md` covers banning it when a client
  picks it by area.
- **Power when suspended** — below what a 0.1 A-resolution meter can read. Bare-board idle is
  already **<0.5 W** (5 V, 0-0.1 A); suspended is smaller still, so the figure would be noise.

## The power key is disabled, both short and long press ❌

**Final position, 2026-09-11:** `HandlePowerKey=ignore`, `HandlePowerKeyLongPress=ignore`. Suspend
itself works; what fails is waking from it, and the BLE remote is the only wake path this board has.
Closed off rather than remapped, because there is no safe target — poweroff is one-way here too,
since BLE cannot wake a powered-down controller.

History, since the policy moved three times: a shared `common/rk35xx-powerkey.conf` once gave every
board `HandlePowerKey=suspend` / `LongPress=poweroff`, so a long press here reached the one-way off
state. Split per board, then both keys set to `suspend`, now both `ignore`. The R69 and H96 Max keep
`LongPress=poweroff` — their IR receiver stays powered and wakes them from off.

❓ **Long press could go back to `poweroff` if BT survives `virtual-poweroff`.** With no PMIC the
rails stay up and the SoC is merely parked, so the chip is not obviously dead — but drivers get
`.shutdown()`, not `.suspend()`, and the console ramoops recovered on 2026-09-07 shows the Seekwave
driver taking the chip down in exactly that path:

```
self skw chip power reset !!
seekwave power down !!
```

That trace is from a `reboot`; `poweroff` shares the `.shutdown()` callbacks, so it is strong
evidence and not proof. To settle it: `poweroff`, then press the remote's power button. If the box
comes back, long press can be `poweroff` here like the other boards. **Test with serial attached** —
if it does not come back the recovery is a power cut, and that is how the last stranding went.

**Off and on are not symmetric, and that is the whole problem.** Turning the box _off_ works over
BLE — the shared drop-in notes long press is reachable over BLE only, because IR stops repeating
before systemd's 5 s threshold. Turning one back _on_ is the opposite: BLE cannot do it on any
board, because the controller is down once the box is asleep. That is why the other boards wake on
**IR** — the receiver stays powered and is a wake source.

This board has no IR receiver. It can therefore be switched off by remote while having **no remote
input capable of switching it on**, with no RTC either, and `rockchip,virtual-poweroff` parking the
SoC rather than cutting rails. Both states are one-way.

🟡 **Which state it actually entered is still unknown**, and that matters for the wake work below.
Suspend and poweroff produce the same symptom here. The journal could not settle it because
`/var/log` is zram and the recovery _is_ a power cut — the evidence destroys itself. Two things to
fix before retrying:

- **Test it with serial attached**, not over ssh. `docs/board-validation.md` already calls serial a
  prospective instrument; this is exactly that case.
- `/var/log` had also **filled** (`rsyslogd: /var/log/syslog write error … No space left on device`,
  looping) on the 47 MB zram. Worth clearing before a timing measurement, since a logging stall
  plausibly contributed to the 10–20 s the transition took.

## Suspend ✅ · waking on the BT remote ❌

Suspend enters and resumes correctly and survives the watchdog window. Waking from it on the remote
does not work, and BT is the only wake path here. Seven faults found, five fixed, two not. The power
key is disabled and the BT-wake patches are parked in `research/h96max-3518d-bt-wake/`. Full
analysis, measurements and rejected approaches live in `research/h96max-3518d-bt-wake`; the short
version:

| Fixed | Fault                                                                        |
| ----- | ---------------------------------------------------------------------------- |
| ✅    | `xhci-hcd` fails `platform_pm_suspend` (-110) — our own USB3 graft           |
| ✅    | SDIO suspend handshake lost to a single-sample race — `0005`, now parked     |
| ✅    | Bluetooth could not wake the host at all — `0004`, parked                    |
| ✅    | Remote hunts to reconnect after the suspend-time disconnect — `0006`, parked |
| ✅    | Authenticated Payload Timeout Expired at 655 s — `0006`, parked              |

| Unfixed | Fault                                                                                     |
| ------- | ----------------------------------------------------------------------------------------- |
| ❌      | The power key's **release** lands ~360 ms after the press, on the far side of the suspend |
| ❌      | The remote **stops responding after ~1 h**; the resulting disconnect wakes the host       |

Masking that disconnect is not available: the host re-enables accept-list scanning in response to
the event, so suppressing it leaves the box unwakeable — shipped once, 19.6 h with zero Bluetooth
packets, recovered by a power cut.

The earlier note here that the residual waker was "not identified" is superseded; all of them were
named from `btmon` traces. Sleep lengths recorded at the time (0.45, 0.48, 6.1, 30, 49, 59.5, 60 s)
were a mix of the power-key release and the payload-timeout event, both since understood.

Two dead ends worth not repeating:

- `skw_sdio_suspend_adma_cmd: timeout gpioin value=1` appears on every cycle and means **nothing**.
  It is an unconditional `skw_sdio_info()` the vendor placed after `skw_sdio_adma_write()`; the word
  "timeout" is in the format string, not in any logic. Not evidence of a failed handshake.
- A single suspend with `wlan0 down` slept 6.1 s, which looked like "not Wi-Fi". Against a 0.45-60 s
  spread one sample proves nothing — the Wi-Fi side is **not** ruled out.

**Next step, in the driver — instrument it first.** The wake is invisible today:
`skw_host_wake_irq_handler()` (`skw_sdio_main.c`) logs the GPIO assertion with `skw_sdio_dbg()`,
which is suppressed at the default level, so nothing records _when_ the chip pulled the line or what
followed. A throwaway debug patch, kept separate from the shipped patches and never merged, should:

- promote that handler's log to `skw_sdio_info()`, including `gpio_get_value()` and whether the host
  is mid-suspend (`atomic_read(&skw_sdio->suspending)`);
- log the port/channel of the first RX after resume, so the ADMA channel (`ch:2`, `ch:5` seen) can
  be mapped to a subsystem — BT's ports come from `pdata->cmd_port` / `data_port` / `audio_port`;
- keep `no_console_suspend` in mind: the console is suspended before the interesting window, so the
  evidence has to survive in the ring buffer and be read after resume.

Only then is it worth changing behaviour. Draining pending traffic before suspend, or not arming the
wake on it, are both DKMS-space and therefore shippable — but neither should be attempted before the
waker is identified, which is the mistake that cost this session twice.

**What the long detour was worth recording.** Fault 3 was chased through the LE accept list, the
suspend scan duty cycle, `HCI_CONN_FLAG_REMOTE_WAKEUP`, an IRK strip and a resume-time absorber —
all of it host-side, none of it in the path. The trace that settled it showed the accept list empty
and no LE scan running during suspend at all, so the Bluetooth stack was never the waker. Two rules
came out of it: check whether a layer is even executing before tuning it, and remember that a DKMS
driver is shippable here while a kernel patch is not — which makes the driver the first place to
look, not the last.

## HDMI 4K ✅ fixed — `esmart_lb_mode`

2026-09-07, on a 4K LG TV. **Symptom:** at 4K the right of the screen was filler, the console
occupying the left part; 1080p was perfect. **Cause:** the factory VOP node sets
`esmart_lb_mode = [03]` = `VOP3_ESMART_2K_2K_2K_2K_MODE`, giving every Esmart window a 2K line
buffer. The primary plane for vp0 is `Esmart0-win0`, so a 3840-wide mode fetched ~2048 pixels per
line and the rest of every line was stale. **Fix:** `[02]` = `VOP3_ESMART_4K_2K_2K_MODE`, which
gives Esmart0 a 4K buffer. Now boots natively at `3840x2160p60`, console `480x135` (3840 px).

Grafted on **all three boards** — they all shipped the same factory `03`.

**What ruled everything else out:** 4K30 (297 MHz, half the pixel clock) failed identically, so the
limit is line _width_, not bandwidth, TMDS rate or any clock. That eliminated the HDMI PHY, the DMC
and the `failed to init opp info` / `failed to get vop bandwidth to dmc rate` warnings, all of which
looked plausible and were not the cause.

The property is read straight from the DT (`of_property_read_u8(…, "esmart_lb_mode", …)`), so there
is no cmdline or module-parameter override, and the VOP cannot be safely unbound while it drives the
console — it needs a DTB and one reboot.

### 8K is not possible on this SoC ➖

`rk3528_vop` declares `max_output = { 4096, 4096 }` and vp0 `dclk_max = 600000000`. 8K is 7680 wide
and 8K60 needs ~2376 MHz. **8K decode works** (that is the VPU) but 8K _display_ does not.

### Still open from the display session

- **`ddc read failed` ×15 from boot.** EDID still parses (256 B, 40 modes) and everything works, so
  it is cosmetic so far, but it is inherited from the factory tree, not our graft.
- **Video playback to the screen** — a real 4K HEVC file, decoded and displayed.

## Open, and doable without the box

- **AVS / AVS+ decode** are the last unfilled cells, and the **lowest-value ones in the matrix** —
  AVS1/AVS+ is Chinese HD broadcast, which is why a Chinese TV-box SoC carries it and why nothing in
  a normal media library uses it. The successor that _does_ appear in modern Chinese content, AVS2,
  already works at **357 fps** on a pkuvcl conformance stream, so the useful half of that row is
  done. For the record it is no longer for want of a clip: FFmpeg's FATE `cavs.mpg` (720×576 CAVS in
  MPEG-PS), demuxed with `ffmpeg -i cavs.mpg -map 0:v:0 -c copy -f data cavs.avs`, makes MPP
  **spin** — endless `loop again`, no frame — under both `-t 16777222` and `-t 16777221`. Either the
  demuxed ES is unclean or the legacy `vdpu2` path does not really do AVS1 here. Not worth chasing
  further unless someone actually feeds this box Chinese broadcast.
- **USB boot in U-Boot.** Not implemented; `# CONFIG_USB is not set`. The USB-A port is the
  `ehci`/`ohci` pair, so a host config needs both, not just DWC3. `docs/todo/rk35xx-uboot-usb.md`.
- **eMMC is capped at HS 50 MHz** by the factory tree and measures right at it. Raising it is a
  tuning question; the R69's HS400 corruption is the reason to be careful.
