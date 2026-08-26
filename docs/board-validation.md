# Board validation — criteria of done

The gate a board passes before it ships. Every line gets **✅ verified · ❌ broken · ➖ not on this
box**, numbers and reasons in `docs/<board>/board.md`. Blank is not an answer; nothing is inherited
from a sibling board.

Run every unattended check before asking the human for anything, then hand them one batched list.
Risk order: SDIO Wi-Fi, the Ethernet PHY, the video codec, anything the DTB touched.

Everything up to **Overlay mode only** applies to any board; that section assumes this repo's
payload and an upstreamed board skips it.

## System

- [ ] `systemd-analyze` recorded; `blame` explains every second and waits on no absent hardware
- [ ] Boot time at or under the board's recorded figure, on the **second** boot
- [ ] `dmesg` accounted for line by line — nothing repeated at any level; tolerated lines named in
      `board.md` with the reason
- [ ] `hostname` and `BOARD_NAME` in `/etc/armbian-release` correct
- [ ] `dkms status`: every module `installed`, and present in `lsmod`
- [ ] Ten warm reboots in a row, and after each one **every device still works** — root mounts, the
      SD enumerates, `wlan0` associates, `hci0` is up, IR responds. Coming back up is not the test
- [ ] `free -m` matches the advertised RAM; `stress-ng --vm --verify` clean
- [ ] `/dev/watchdog` exists, systemd took it, `wdctl` then reports it busy
- [ ] The granted timeout is the **largest** step the watchdog clock allows, not the first one that
      works — `journalctl -b | grep "Watchdog running with"` against `2^(16+TOP)/clk`
- [ ] `board.md` carries identity, on-disk names, measured numbers and known gaps; `worklog.md` was
      written as the work happened; the README lists the board

## CPU, thermal, power

- [ ] `scaling_available_frequencies` matches the **factory** OPP table
- [ ] 5 min 4-core `stress-ng`: idle and peak against `trip_point_*_temp`, no throttling
- [ ] Draw metered at idle, suspended and off — **bare board, no peripherals connected**
- [ ] `PM: suspend entry (deep)` in dmesg, and `deep` bracketed in `/sys/power/mem_sleep`
- [ ] Suspend, resume on the remote, and it **stays** up — no logind double-fire
- [ ] Suspend for **longer than the watchdog window** and resume: same `boot_id`, not a cold boot
- [ ] Same with the remote in BLE mode: it reconnects after resume and still drives the box. Waking
      is always the IR path, because Bluetooth is dead in suspend and in off
- [ ] Cold-boot time from off, timed
- [ ] RTC present and keeping time, or its absence recorded

## Storage

- [ ] eMMC: `fio` sequential + random 4K, direct I/O, the same parameters as every other board
- [ ] SD: enumerates, hotplug insert **and** remove, `fio` recorded
- [ ] Boots from eMMC on its own loader pair — `dd` sectors 64 and 16384
- [ ] After migration, sectors 7168–16383 are byte-identical to the backup; only the GPT, the
      idbloader and `u-boot.itb` differ
- [ ] `DVKR` at sector 7168 and `SSKR` at 8192 still tagged; `LAN_MAC` still the sticker address
- [ ] Maskrom proven **before** it is needed — recovery button at power-on, `rkdeveloptool ld`
      reports `Maskrom`

## Ethernet

- [ ] Link speed and duplex as the hardware allows
- [ ] `readlink /sys/class/net/end0/phydev/driver` is the vendor PHY, not Generic
- [ ] Throughput idle **and** under 4-core load
- [ ] MAC matches the sticker, and survives reboots and eMMC migration
- [ ] Wake-on-LAN works, or `phy-is-integrated` is recorded as the reason it cannot

## Wi-Fi

- [ ] Associates on 2.4 GHz **and** 5 GHz; band and PHY rate from `iw dev wlan0 link`, or
      `wpa_cli -i wlan0 status` (`freq=`) where `iw` is not installed
- [ ] Throughput idle **and** under 4-core load, both bands
- [ ] No latch — after the load stops, baseline returns at once or within 60 s
- [ ] MAC stable across three reboots, and again after eMMC migration

## Bluetooth

- [ ] `hci0` `UP RUNNING`, `errors:0`, not rfkill-blocked on a fresh image
- [ ] `btmgmt find` returns devices
- [ ] `BD_ADDR` identical across three reboots
- [ ] The bundled remote pairs, works, and the pairing survives a reboot
- [ ] A2DP to a speaker, or recorded as untested

## Display

- [ ] Picture on a real TV at native resolution; `modetest -c` mode list sane, EDID parses
- [ ] 1080p60 and 4K60 both drive the panel
- [ ] A PC monitor too — the pixel-clock quirk bites there, not on TVs
- [ ] HDMI audio (`aplay -D hdmi:…`), and it is the default sink
- [ ] CEC: `cec-ctl` finds the adapter, the TV remote reaches the box, `cec-client` sees traffic
- [ ] HDMI hotplug re-detects, with no blank screen afterwards
- [ ] AV jack: composite video **and** analog audio
- [ ] GPU renders under `kmscube` / `glmark2-es2`, fps recorded

## Video codec

Test every cell at **720p, 1080p, 4K and 8K** — both surprises this repo found were at the extremes.

- [ ] MPP names the SoC — `match chip name: …`, not `use default chip info`
- [ ] The matrix below filled, as a normal user, fps recorded
- [ ] A real 4K HEVC file plays smooth and in sync with the CPU near idle

| Format                        | Decode | Encode | Pass means                                 |
| ----------------------------- | :----: | :----: | ------------------------------------------ |
| H.264 · HEVC · MJPEG          |   ✔    |   ✔    | the encode **decodes back**, not just >0 B |
| VP9 · AVS2                    |   ✔    |   —    | VP9 also settles `rk3528a` vs `rk3528`     |
| MPEG-2 · MPEG-4 · H.263 · VP8 |   ✔    |   —    | legacy VPU2 block, ≤1080p                  |
| AVS · AVS+                    |   ✔    |   —    | 🟡 is honest when no clip exists           |
| AV1                           |   ➖   |   ➖   | absent — record MPP's refusal              |

## USB

- [ ] USB 2: enumerates at `480M`, throughput recorded
- [ ] USB 3: negotiates `5000M`, `uas` bound not BOT, `fio` sequential + random 4K
- [ ] Every port individually — they are not interchangeable
- [ ] Hotplug in and out on each, no dmesg complaints
- [ ] Bus power: a self-spinning 2.5" HDD starts, or the limit recorded

## IR, buttons, LEDs

- [ ] IR receiver: an input node exists, and its IRQ in `/proc/interrupts` counts up while the
      remote is pressed
- [ ] Every remote button captured with `evtest`; keymap table in `board.md`
- [ ] IR-extender jack, if the board has one
- [ ] Power on the remote cold-boots the box from off
- [ ] Long press tested in the mode the remote is actually in — IR or BLE
- [ ] Toothpick/recovery button registers on the `adc-keys` node
- [ ] LED polarity confirmed by eye: running, suspended, off

## Overlay mode only

Skip on an upstreamed board — it takes kernel, DTB and identity from Armbian's own packages and
never reads `firmware/` or `/usr/local/share/*/`.

- [ ] Identity dir populated and correct: `board-id`, `board-name`, `board.dtb`, both loaders
- [ ] No other board's names under `/etc`, `/usr/local`, `/usr/lib/systemd`, `/usr/src`
- [ ] Loaders on disk match the identity dir — `dd` sectors 64 and 16384, md5 against
      `/usr/local/share/*/`
- [ ] Survives `apt full-upgrade`: `BOARD_NAME` intact, `linux-u-boot-*` held
- [ ] Both update paths work — `rk35xx-deploy` from a host, `rk35xx-update --pull` on the box
- [ ] Payload udev rules fire: anything a recipe names as `event<N>` has its `SYMLINK+=`
- [ ] The dtb-persist hook survives a kernel update — `/boot/dtb-*/rockchip/board.dtb` still matches
      `/usr/local/share/*/board.dtb`

## Needs the human — batch these into one list

- LED polarity: running, suspended, off
- Every remote button under `evtest`, for the keymap table
- Wake from off on the remote
- Suspend and resume, in IR mode and in BLE mode
- Toothpick/recovery button
- HDMI on a real TV, and on a PC monitor
- A real 4K HEVC file playing
- A device in each USB port
- SD card insert and remove
- AV jack
- Power meter at idle / suspended / off, bare board
- BT remote pairing
- eMMC migration, and the device name it asks to confirm

---

# Caveats

## Measuring

- `ssh` is not a throughput test — its encryption is itself CPU load. Use `iperf3` or `nc`.
- Measure the **second** boot; the first legitimately spends a minute on resize and first-run setup.
- First boot compiles DKMS offline — allow ~4 minutes before calling it a failure.
- Level-filtering `dmesg` hides most of it: on the R69, 914 lines against 121 for `-l err,warn`.
  Judge a line by whether it tells the reader something, not by the level it was logged at —
  demoting a chatty `dev_err` to `dev_dbg` hides it rather than fixing it.
- `stock/<board>/dmesg.txt` is only a baseline if it covers early boot. The R69's starts at 523 s
  because the ring buffer had wrapped, so it classifies nothing and passes everything.
- **The `fio` parameters are fixed** — identical on every board and every medium, or the numbers do
  not compare. 1 MiB blocks at `iodepth=8` sequential, 4 KiB at `iodepth=32` random, always
  `--direct=1` so nothing is served from page cache:

  ```sh
  fio --name=seq  --filename=<file> --rw=read|write         --bs=1M --size=1G   \
      --direct=1 --ioengine=libaio --iodepth=8  --numjobs=1 --runtime=30 --time_based
  fio --name=rand --filename=<file> --rw=randread|randwrite --bs=4k --size=512M \
      --direct=1 --ioengine=libaio --iodepth=32 --numjobs=1 --runtime=30 --time_based
  ```

  Record decimal MB/s; `fio` reports KiB/s, so `bw=371MiB/s` is 389 MB/s. Let a drive idle a few
  seconds between phases — it throttles thermally, and a read taken straight after heavy writes
  under-reported by ~12%.

- `glmark2-es2-drm` needs a VT and an **unoccupied** display. Over SSH it prints
  `Failed to become DRM master`, and so does `openvt` while an earlier run still holds
  `/dev/dri/card0` — that leftover is the usual cause, not permissions. `fuser -v /dev/dri/card0`,
  `pkill -9 -f glmark2`, then `openvt -s -w -- sh -c 'glmark2-es2-drm > /tmp/gl.log 2>&1'`.
- Codec tests run as a **normal user** — the nodes ship `0600` and root hides a missing udev rule.
  Record fps: a silent fall back to software is the failure the matrix exists to catch.
- **A warm reboot is not a cold one, and one of them is not a test.** On this family a `dwmmc`
  controller can return `-110` on its first init after `reboot` and never recover — the SD root goes
  missing, or the SDIO Wi-Fi comes up wedged — while a cold power cycle always clears it. It is
  intermittent and per-driver (the `sdhci` eMMC has never done it), so reboot ten times and watch
  the root mount and `wlan0` specifically.
- A boot that has grown since the last measurement is the cheapest signal something is wrong. Usual
  causes: a unit waiting on absent hardware, a getty retrying a tty, a first-boot script that never
  marked itself done, DHCP on an unplugged interface, a DKMS rebuild meant to happen once.

## Network under load

- A >20% drop, latency spikes into hundreds of ms, retries climbing in `iw dev wlan0 station dump`,
  or driver errors in `dmesg` are all worth investigating.
- A slowdown under load is contention and expected; a link that does not return afterwards is a
  **latch** and a defect. Stop the load, re-measure immediately and again after 60 s idle; `tx` far
  below `rx` at a strong signal is the signature. Record which rung clears it — reassociate, reload
  the module, reboot.
- Check where the interrupts land before reaching for anything else —
  `grep -E "mmc|sdio|eth|gmac|dwmac" /proc/interrupts`. Remedies, cheapest first: pin the IRQ
  (`/proc/irq/<n>/smp_affinity`), spread receive processing
  (`/sys/class/net/<if>/queues/rx-0/rps_cpus`), then raise the driver's own bus threads — the
  AIC8800 exposes `bustx_thread_prio` and `busrx_thread_prio` under
  `/sys/module/aic8800_fdrv/parameters/`. Any of them is board data and ships in the payload with
  the measurement that justified it.

## MAC addresses

- A moving IP after a reboot means the MAC is not pinned, not DHCP. Compare
  `/sys/class/net/wlan0/address` across three boots.
- A valid but **wrong** address wins, and `dwmac-rk` takes any valid address it is handed. On these
  images that address comes from mainline's `rockchip_setup_macaddr()` — SHA256 of the OTP `cpuid#`,
  multicast cleared, LA bit set — because our U-Boot has no vendor-storage driver to read `LAN_MAC`
  with. Deterministic, so it will not churn; still not the sticker. Check against the sticker, not
  against the last boot.
- Order of truth: vendor storage `LAN_MAC` (the sticker) → chip efuse → SoC OTP id. Random is the
  bug, never the fallback; derive the tail from the SoC serial instead. Never a rootfs file, never a
  rename-after-the-fact unit.
- **A derived address is locally administered** — bit `0x02` of the first octet. Neither `C4:2A:FE`
  nor `88:00:33` is a registered OUI, so deriving under them squats on space that is not ours;
  `rk35xx-mac-pin` sets the bit whatever `mac-oui` says. Addresses read from vendor storage are
  assigned and stay untouched.
- `CONFIG_WIFI_GENERATE_RANDOM_MAC_ADDR` generates an address once and persists it with
  `rk_vendor_write()`; if that write fails — an uninitialised or read-only vendor storage partition
  will do it — the driver silently generates a fresh one every boot.
- Before blaming that write, check the driver reaches the code at all. The symbol only gates
  `get_wifi_addr_vendor()` in `net/rfkill/rfkill-wlan.c`, which a Wi-Fi driver must opt into by
  calling `rockchip_wifi_mac_addr()`. Vendored SDIO drivers routinely hide that behind their own
  `CONFIG_PLATFORM_*` knobs and then ask the firmware, which invents one per boot.
  `grep -c rfkill-wlan` over a boot log settles it: zero means vendor storage is not the problem.
- Bluetooth has the same requirement and a worse failure — a wandering `BD_ADDR` invalidates every
  pairing on every boot, and nothing in the logs says why.

## Power

- No RTC on this family, so no `rtcwake`.
- **Wake-on-LAN cannot work** with an integrated PHY (`phy-is-integrated`, no `phy-supply`): deep
  suspend powers it down, so nothing is left to see the magic packet. Exhausted on the R69 —
  `ethtool -s end0 wol g`, `power/wakeup: enabled`, `RKPM_GMAC_WKUP_EN` in `rockchip,wakeup-config`,
  ten magic packets, no wake. No Rockchip board in this BSP enables that wake bit either.
- **Never suspend a box remotely** — it is stranded until someone presses the remote.
- Expect off to cost **more** than suspend: with no PMIC, `rockchip,virtual-poweroff` parks the SoC
  with the rails up and DDR out of self-refresh, and drivers get `.shutdown()` not `.suspend()`. Do
  not fix that by dropping rails — suspend has a standard mechanism
  (`regulator-state-mem { regulator-off-in-suspend; }`, 130 Rockchip boards in-tree) and poweroff
  has none, so cutting a rail there splits one behaviour across layers. Prefer suspend.
- Meter the bare board — nothing in USB, no HDMI — or the numbers are not comparable between boards.
  A USB stick and HDMI moved every R69 figure by several tenths of a watt. Any measurement with
  peripherals attached is a separate row, labelled with what was plugged in.

## Recovery

- The watchdog is also the only hang recorder: its reset preserves ramoops to
  `/var/lib/systemd/pstore/`, and a cold power cycle loses it. It is unconditional and cannot be
  disarmed once armed, so a board that hangs early will loop — and its count carries across a soft
  reboot, which `watchdog.md` covers.
- Serial is a **prospective** instrument — attaching it to an already-hung box shows nothing,
  because the interesting output scrolled past. Attach it, then reproduce.
- `armbian-install` clears the first 16 MiB to lay down partitions. Upstream keeps sectors
  7168–16383 when it finds the `DVKR`/`SSKR` tags, and **that is the whole of the protection** —
  everything else there is overwritten and nothing restores it, so a full eMMC backup before any
  migration is mandatory.
