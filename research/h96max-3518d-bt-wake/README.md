# H96 Max 3518D — waking from suspend on the BT remote

Suspend itself works: the board enters `deep`, resumes with the same `boot_id`, and survives past
the watchdog window. **Waking it from the BLE remote is what does not work.** Seven faults were
found; five are fixed, two are not, and the two that remain have no known fix that does not create a
worse failure.

**Shipped position:** `HandlePowerKey` and `HandlePowerKeyLongPress` are both `ignore`, so the
remote cannot reach suspend. `systemctl suspend` still works and is unsupported, because on this
board there may be no way back.

## Why only this board

The R69 and H96 Max both suspend and wake fine — over IR. On those, Bluetooth is dead in suspend and
off, and only the IR receiver is armed as an ATF wake source; the dual-mode remote falls back to IR
whenever the BLE link drops, so BT wake was never needed and never worked there either.

This stick is the only board with no IR receiver fitted, which forces it onto the one path nobody
had ever made work. The faults below are not regressions — they are a path used in earnest for the
first time.

What that leaves:

- No RTC and no `wakealarm`, so nothing can bring the box back on a schedule.
- No IR receiver, so no second input path.
- Every wake arrives on `pm_wakeup_irq 66`, the SDIO host-wake shared with Wi-Fi.
- `dw_wdt_suspend()` gates the watchdog clock, so a box that will not wake needs the power pulled.

One wake source, no fallback, a hard recovery cost. That is why each failure below was expensive to
test.

## Fixed

**1. `xhci-hcd` fails `platform_pm_suspend` (-110), aborting suspend.** Our own USB3 graft:
`maximum-speed` plus a disabled `combphy` leaves the SuperSpeed half present and unclocked, and it
never halts. Graft reverted; this one ships.

**2. The SDIO suspend handshake was skipped every time.** `send_host_suspend_indication()` samples
the chip's "traffic pending" GPIO once, and suspend generates traffic of its own, so the one sample
it takes is the moment the line is most likely high. The chip was never told the host went down and
kept asserting the line until the wake-enabled interrupt resumed the box. Fixed by `0005`, parked
here.

**3. Wake ~3 s after every suspend.** `hci_suspend_sync()` disconnects every link, and this handset
answers with `ADV_DIRECT_IND` to reconnect. Waking on an accept-listed device's advert _is_ the
upstream design and cannot be filtered, because a keypress from a bonded remote sends the same PDU.
Fixed by `0006`, parked here.

**4. Wake at exactly 655 s, or 30 s at the default.** Authenticated Payload Timeout Expired. The bit
lives in event mask **page 2**, which `HCI_INIT` writes once and no suspend path revisits. Measured
exactly: the event fired **655.41 s after the last keypress**, against an `auth_payload_timeout` of
0xffff (655.35 s). Every keypress refreshes it. Fixed by clearing page 2, in `0006`.

**5. Bluetooth could not wake the host at all.** The driver never set `hdev->wakeup`, so
`hci_suspend_sync()` took its early return and armed no accept list. Fixed by `0004`, parked here.

Fault 5 has a second half that is **not** in the driver: the kernel refuses to accept-list a device
whose IRK it holds while LL privacy is off — `hci_le_add_accept_list_sync()` returns `-EINVAL` — so
the list stays empty. `rk35xx-bt-wake` here strips the IRK before bluetoothd reloads it.

## Not fixed

### A. The remote's power-key release wakes the box, ~0.4 s

**Root cause — confident.** The button sends press and release ~360 ms apart. `logind` suspends on
the press; with the link held open the release is delivered on the far side of the suspend and
resumes immediately. Measured 0.37 s of sleep against a 364 ms press-to-release gap, in the same
trace, minutes apart from a 4422 s success entered via `systemctl suspend`.

**Why unfixed.** A `system-sleep` `pre` hook waiting for the key to be released (`evtest --query`)
would close the common case but only narrows the window — a release landing during CPU-down still
gets through.

### B. The link dies after ~1 h idle and the disconnect wakes the box

**Root cause — partly confident.** The remote stops responding after roughly an hour of inactivity
and the link is torn down; `Disconnect Complete` then pulls host-wake. What is **not** established
is why the remote stops. It is firmware behaviour, unreachable from the host.

Raising the supervision timeout only moved which timer fired first:

| Supervision timeout | Slept    | Disconnect reason         |
| ------------------- | -------- | ------------------------- |
| 3000 ms             | 3598.3 s | Connection Timeout, 0x08  |
| 32000 ms            | 3649.7 s | LL Response Timeout, 0x22 |

A 10× increase changed the reason code and not the hour, so this is not RF margin.

**Why masking the event is not the answer — confident.** Three adjacent packets:

```
> HCI Event: Disconnect Complete            #1959
< HCI Command: LE Set Extended Scan Params  #1960   Filter policy: Ignore not in accept list
< HCI Command: LE Set Extended Scan Enable  #1962   Extended scan: Enabled
```

The host re-enables accept-list passive scanning **as a consequence of** that event. Scanning is off
while a link is up. Mask the event and it is never re-enabled, so no later advertisement is heard.
Shipped once: 19.6 h asleep with **zero** Bluetooth packets and no keypress able to wake it;
recovery was a power cut.

A second defect compounds it. Masked HCI events are discarded, not queued, so the host keeps a
phantom connection and would ignore an advert from a device it believes is still attached.

The controller does support what a fix would need — `LE Read Supported States` reports _Passive
Scanning State and Connection State (Central Role)_ — so pre-enabling the scan before suspend is
possible. It does not address the phantom connection, which would need the driver to detect the dead
handle and synthesise a `Disconnect Complete` into the stack.

## Tried and rejected

- **`auth_payload_timeout=65535`** — fixes fault 4's event, does not touch B. Superseded by clearing
  page 2, which removes the event rather than deferring it to the spec maximum.
- **Supervision timeout 3000 → 32000 ms** — persists correctly via BlueZ's device store, and changes
  the disconnect reason code only.
- **Masking `Disconnect Complete`** — unwakeable box, recovered by a power cut. See above.
- **Reducing the LE Ping rate to make B rarer** — 655 s pings versus 30 s pings gave 3598 s versus
  3650 s of sleep, so ping rate is not the mechanism.

## What mainstream does

Upstream's design — the ChromeOS "Handle system suspend gracefully" series — disconnects at suspend
and wakes on the bonded device's reconnect advert, aiming to "wake the system when a HID device
receives user input but otherwise not send events to the host". It assumes a disconnected peripheral
stays quiet; this one re-advertises in ~3 s. The common workaround in the wild is to disable BT wake
entirely, which is not available here because it is the only wake source.

Embedded vendors solve it in controller firmware (NXP AN12849): the chip decides what pulls
host-wake, so link maintenance never reaches the host. This Seekwave firmware pulls host-wake for
every HCI event.

`HCI_QUIRK_NO_SUSPEND_NOTIFIER` is also used off-label here. It exists for controllers that drop off
the bus during suspend and are re-probed on resume, such as Realtek USB dongles. Using it to keep a
link alive works only because it skips the entire suspend sequence — which is where faults 3, 4 and
B come from.

## What is parked here

Nothing in this directory is applied or installed. `fetch-seekwave-src.sh` globs
`patches/seekwave-swt6621s/*.patch`, so these patches reach no build.

- `0004` — sets `hdev->wakeup`, so `hci_suspend_sync()` configures an accept list. Proven; without
  it Bluetooth can never wake the host.
- `0005` — waits for the chip's traffic GPIO instead of sampling it once. Proven on the 3518D
  against a measured race: the line reads low 88% of the time while idle, yet read high at all five
  consecutive suspends.
- `0006` — `HCI_QUIRK_NO_SUSPEND_NOTIFIER` plus clearing event mask page 2. Nearly worked, 3598 s,
  but one run with it active ended with the box hung.
- `rk35xx-bt-wake` — drops the remote's IRK so the kernel will accept-list it. Necessary for any
  accept-list wake.
- `bt-wake.conf` — runs that as bluetoothd's `ExecStartPre`.
- `skwbt-options.conf` — the modprobe opt-in that enabled the quirk.

**Parked for lack of a consumer, not because they are doubtful.** `0004` and `0005` are sound and
`0005` would stand as an upstream submission unchanged. Only `0006` carries real risk. The patches
apply on top of the shipped set in numeric order, verified against pinned commit `b1b15016`.

## Unexplored — the HID Control Point is never written

**The most promising untested lead.** HID-over-GATT mandates a **HID Control Point** characteristic,
UUID `0x2A4C`. The host writes `0x00` to tell the device it is entering Suspend and `0x01` on
resume; devices are expected to answer by cutting keypress scan rate, dropping LEDs and going quiet.
That is the state this whole investigation was trying to induce by other means.

**It is never written here.** Zero occurrences of `0x2A4C` across every capture taken. Every ATT
write we make to the remote is a CCCD notification-enable (`0x2902`), plus one Report access.

**That is upstream behaviour, not local misconfiguration.** BlueZ defines the UUID as
`HOG_CONTROL_POINT_UUID`, but its HoG Suspend/Resume series puts the trigger behind an explicit,
selectable backend — the reference implementation is a FIFO at `/tmp/hogsuspend`, where writing
`suspend` or `resume` updates the control point. Deliberately not tied to system suspend: the author
rejected UPower signals because the connection is dropped immediately after the suspend signal
arrives. So nothing in a stock stack tells a HoG peripheral that the host is going to sleep.

Every fault above therefore happened with the remote believing the host was fully awake — the
reconnect hunt, the payload-timeout pings, and the ~1 h drop alike.

**The test.** Find the `0x2A4C` handle (it is mandatory inside the HID service, and BlueZ caches the
attribute database under `/var/lib/bluetooth/<adapter>/cache/<device>`), write `0x00` to it before
suspending, and watch whether fault B still fires at the hour and whether the remote goes quiet
instead of hunting. On resume, write `0x01`. If the remote honours it, this replaces both the quirk
and the masking with a single documented write, and needs no driver patch at all.

**What would make it fail.** Cheap handsets commonly expose the control point to satisfy the profile
and then ignore the value. The capability is only established by the write changing observed
behaviour, not by the characteristic being present.

The remote's other services offer nothing for this: `ab5e0001-5a21-4f05-bc7d-af01f617b664` is the
Android TV voice service (TX/RX/CTL for audio capability negotiation) and `0xae00` at handles
`0x0080-0x0085` is an unidentified 16-bit vendor service, not yet enumerated.

## Also unexplored

- `adc-keys` (`event3`) and `hdmi_cec_key` (`event1`) exist as input devices. Neither has been
  checked for `power/wakeup` capability. A working physical wake would remove the power-cut recovery
  cost and make further experiments cheap.
- One run with the quirk active ended with **both LEDs off** — a state no hook here produces, so a
  hang rather than a suspend. Never reproduced, cause unknown.
