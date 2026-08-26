# Armbian for RK35xx TV boxes

Run Debian on a **$35 RK3518 Android TV box**. Silent, fanless, complete in the box: case, PSU, HDMI
cable, IR + Bluetooth remote.

> **Side benefit:** these boxes have a documented history of preinstalled malware (BADBOX); Armbian
> replaces that userspace wholesale.

Not a distro — a thin layer over the stock **[Armbian ROCK 2F](https://www.armbian.com/rock-2f/)**
image (same RK3528-family kernel): factory DDR bootloader, device tree, whatever DKMS drivers the
board's silicon needs, boot fixups. Kernel and userspace keep coming from `apt upgrade`.

**Why an overlay and not an Armbian board?** An evening's work, and a board stays just data.
Upstreaming means merging every change into one shared kernel without side effects for the other
boards on it, hunk by reviewed hunk. Tried and withdrawn —
[build#10440](https://github.com/armbian/build/pull/10440) and
[linux-rockchip#528](https://github.com/armbian/linux-rockchip/pull/528). Nothing is lost by staying
downstream, and the board-independent kernel fixes go upstream on their own.

## Boxes

|            | **R69**                                     | **H96 Max** "H313"                             |
| ---------- | ------------------------------------------- | ---------------------------------------------- |
| Box        | <img src="docs/r69/image1.jpg" width="300"> | <img src="docs/h96max/image1.jpg" width="300"> |
| Board      | <img src="docs/r69/board.jpg" width="300">  | <img src="docs/h96max/board.jpg" width="300">  |
| Board key  | `r69`                                       | `h96max`                                       |
| Silkscreen | `XR821_V1.1`                                | `3518_ZX_V01 20250818`                         |
| SoC        | RK3518                                      | RK3518                                         |
| RAM        | 2 GB (1.5 GB usable)                        | 2 GB                                           |
| eMMC       | 16 GB Samsung                               | 16 GB Micron                                   |
| Wi-Fi / BT | AIC8800D80                                  | Seekwave SWT6621S                              |
| Details    | [board doc][r69]                            | [board doc][h96]                               |

[r69]: docs/r69/board.md
[h96]: docs/h96max/board.md

## What works

✅ verified here · 🟡 not tested · ❌ broken · ➖ not present. Per board, never inherited; the
numbers behind each ✅ are in the board docs.

**✅ on both boxes** — SD boot · eMMC install · warm reboot · DKMS built offline at first boot ·
watchdog · serial console · suspend-to-RAM `deep` · wake from off/suspend by remote · no throttling
under 5 min 4-core load · temperature sensor · eMMC and SD · USB 2 at 480M · USB 3 at 5000M with
`uas` · Ethernet 10/100 · Wi-Fi 2.4 and 5 GHz · Bluetooth · BLE remote pairing · HDMI video and
audio · GPU under lima · IR remote · air-mouse · toothpick button · power button · LEDs.

**✅ codecs, both boxes** — decode H.264 · HEVC · MJPEG · VP9 to **8K**, and MPEG-2 · MPEG-4 · VP8 ·
H.263 to 1080p; encode HEVC · MJPEG to **8K**, H.264 with MPP ≥ `905020444`. VPU nodes are usable as
a normal user.

| Differs by board              | R69 | H96 Max |
| ----------------------------- | :-: | :-----: |
| Maskrom recovery over OTG     | ✅  |   🟡    |
| Draw metered idle/suspend/off | ✅  |   🟡    |
| Wire speed under 4-core load  | ✅  |   🟡    |
| IR-extender jack              | 🟡  |   ➖    |

**🟡 untested on either** — restoring a backup to eMMC · SD hotplug removal · USB bus power for a
self-spinning drive · HDMI 4K60 and EDID mode list · HDMI-CEC · HDMI hotplug re-detect · AV jack
audio and composite video · AVS/AVS+/AVS2 decode · remote voice mic.

**➖ not present** — CPU deep idle · Wake-on-LAN (the PHY is inside the SoC) · AV1.

> **One open H96 Max defect sits behind a ✅ cell above:** a **warm reboot can come up without
> `wlan0`** — the box returns, the radio may not. The 2.4 GHz **TX latch at 6 Mbit/s** is
> root-caused and carries a driver patch as of 2026-08-25, pending confirmation on a built image.
> Evidence and current state in `docs/todo/`.

## Build

Needs a **microSD** (8 GB+) and a stock ROCK 2F `.img.xz` (tested: `minimal` vendor 6.1).

```bash
brew install xz coreutils                    # macOS  ·  apt install xz-utils on Debian
./build-e2tools.sh                           # once — stock e2tools corrupts an image on delete
./build-image.sh Armbian_..._Rock-2f_..._minimal.img.xz h96max      # board: r69 | h96max
```

~1 minute, no Docker, no kernel build. Output: `Armbian_..._-<board>.img`.

## Flash and boot

```bash
diskutil list                            # macOS — find the card   ·   lsblk on Linux
diskutil unmountDisk /dev/diskN
sudo gdd if=Armbian_..._-h96max.img of=/dev/rdiskN bs=4M conv=fsync status=progress; sync   # macOS
sudo dd  if=Armbian_..._-h96max.img of=/dev/sdX    bs=4M conv=fsync status=progress; sync   # Linux

ssh root@<box-ip>                        # Armbian default password for root is 1234
```

…or [Balena Etcher](https://etcher.balena.io/). Insert the card and power on. Stock Android is
untouched — **eject the SD and Android boots again.**

> **First boot takes ~5 minutes** — DKMS modules compile offline and the box is off the network
> until they finish. Still nothing? [Serial console](#serial-console).

## Install to eMMC

Faster than any SD card. **Wipes Android and everything the factory wrote to that chip.** Boot from
SD, dump the whole chip somewhere durable, then install — in that order.

```sh
lsblk                                        # the eMMC is the disk with mmcblkXboot0/boot1 beside it
sudo dd if=/dev/mmcblkX bs=4M status=progress | ssh you@host 'cat > emmc-stock.img'

sudo armbian-install                         # choose "Boot from eMMC / system on eMMC"
sudo poweroff                                # pull the SD; it boots from eMMC
```

Dump the **disk**, not partitions; check `stat -c %s emmc-stock.img` = `cat /sys/block/mmcblkX/size`
× 512, and keep it off the box **and off the SD card**.

> **Never trust remembered device names.** `mmcblk` numbering shifts between images and boots; the
> eMMC is the disk with **`boot0`/`boot1` companions**.

> **`armbian-install` destroys more than Android**, and the fix has not shipped yet. It zeroes the
> first 10 MiB, taking vendor storage (`DVKR`, sector 7168 — the `LAN_MAC` on your box's label) and
> secure storage (`SSKR`, 8192 — HDCP/DRM keys) with it. None of it regenerates. Assume it happened
> and put the window back from your dump; `end0` on a derived address instead of the label one is
> the tell. Full account: `docs/armbian-install.md`.
>
> ```sh
> dd if=emmc-stock.img bs=512 skip=7168 count=9216 of=window.bin          # on the host
> sudo dd if=window.bin of=/dev/mmcblkX bs=512 seek=7168 count=9216 conv=notrunc,fsync
> sudo rk35xx-vendor-storage lan                                          # expect the label address
> ```

Afterwards only the partition table (sectors 0–5) and the U-Boot region should differ:

```sh
sudo dd if=/dev/mmcblkX bs=512 count=32768 \
  | cmp -l - <(ssh you@host 'dd if=emmc-stock.img bs=512 count=32768 2>/dev/null')
```

> **Wrong loaders are recoverable.** Stock `armbian-install` writes ROCK 2F ones this DRAM can't
> run; our images override that write. On images older than August 2026, update first
> ([#6](https://github.com/sormy/rk35xx-tvbox-armbian/issues/6)).

## Update a running box

For changes in **this repo** — DTB, drivers, scripts. Everything else: `apt upgrade`.

```bash
./rk35xx-deploy root@<box-ip>     # push this repo and apply  (--reboot if the DTB changed)
sudo rk35xx-update --pull         # …or on the box, fetching the repo itself
```

Installs the payload, rebuilds DKMS, reinstalls the DTB, restarts what changed; reboots only if
`board.dtb` did, never touches the bootloader. It **overwrites the files it ships** — keep
customisations elsewhere.

> **R69 boxes deployed before the naming was unified**: the `r69-*` commands are gone. Run
> `sudo rk35xx-update --pull` once — it recognises the old layout and removes what it replaces.

## Remote

IR works unpaired; Bluetooth adds air-mouse and battery. Keycodes differ per remote — check yours
with `sudo evtest /dev/input/ir-remote`.

To pair, hold **left + right until the remote's LED blinks**, then find the entry named
**`Bluetooth remote`**. It must be **one `bluetoothctl` session with a scan running** — a separate
`pair` fails with `org.bluez.Error.AuthenticationFailed`:

```sh
sudo apt install bluez            # minimal images ship without it

# 1. remote in pairing mode (LED blinking), then find it by name:
MAC=$(bluetoothctl --timeout 20 scan on | grep -im1 "bluetooth remote" \
      | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}')

# 2. put it back in pairing mode, then pair with the scan running:
{ echo "agent NoInputNoOutput"; sleep 1; echo "default-agent"; sleep 1; echo "scan on"; sleep 8
  echo "pair $MAC";  sleep 20; echo "trust $MAC"; sleep 2
  echo "connect $MAC"; sleep 8;  echo quit; } | bluetoothctl
```

`bluetoothctl remove $MAC` drops the bond, `disconnect` parks it.

> Dead IR? Your remote's usercode isn't in the DTB's scancode tables — same model name, different
> remotes.

## Serial console

**Set this up first** — the only view of U-Boot and of any hang before the network. **3.3 V**,
**1500000 baud**. Both cases open with a plastic pry tool (clips, no glue); the H96 Max needs a
couple of screws out to reach the pads from the back.

| Board       | Where                                       | Pinout, `[square pad]` first |
| ----------- | ------------------------------------------- | ---------------------------- |
| **R69**     | 4-pad header beside the SD slot             | **[GND] · TX · RX · 3V3**    |
| **H96 Max** | 3 plated holes between the SD slot and LEDs | **[RX] · GND · TX**          |

- **Adapter:** 3.3 V USB-TTL doing 1.5 Mbaud — **FT232 or CH340**, e.g.
  [Waveshare FT232RNL](https://www.amazon.com/dp/B0CX55K4RG) (~$14). **Not a CP2102**: it can't, and
  renders the boot log as plausible garbage.
- **Wiring:** GND, TX, RX only, crossed (box TX → adapter RX). **Never connect 3V3/VCC** — the box
  is self-powered and tying rails can backfeed.
- **Contact:** no soldering — [test-hook grabbers](https://www.amazon.com/dp/B07BCZSNGS) (~$10).

```bash
brew install tio                                              # or: apt install tio
tio -b 1500000 -L --log-file boot.log /dev/cu.usbserial-XXXX  # macOS: cu.*, not tty.*
tio -b 1500000 -L --log-file boot.log /dev/ttyUSB0            # Linux
```

Power-cycle and the log scrolls; you get a login prompt, and U-Boot's countdown is interruptible.
Output but no input → recheck contact and the TX↔RX crossing. Full kernel log on serial and HDMI →
set `verbosity=7` in `/boot/armbianEnv.txt`.

## Recovery

**SD still boots** — bad rootfs, bad DTB, botched install. Boot the Armbian SD and write the backup
back over the eMMC: `sudo dd if=emmc-stock.img of=/dev/mmcblkX bs=4M status=progress; sync`.

**Nothing boots, not even the SD.** USB-A-to-A male-to-male to the host (A-to-C adapter if it only
has USB-C), trying both ports — only the OTG one enumerates. **The cable does not power the box** —
VBUS on that port is board-sourced (`vcc5v0_otg`, a fixed regulator off `vcc5v0_sys`), so it is an
output. Connect USB first, then hold the recessed button inside the AV jack, apply the power cable,
and keep holding ~3 s before releasing:

```sh
./build-rktools.sh                                     # rkdeveloptool + a loader per board
./tools/rktools/rkdeveloptool ld                       # Vid=0x2207,Pid=0x350c  Maskrom
./tools/rktools/rkdeveloptool db tools/rktools/rk3528_spl_loader-<board>.bin   # DDR init; first
./tools/rktools/rkdeveloptool wl 0 emmc-stock.img      # restore the whole eMMC
./tools/rktools/rkdeveloptool rd                       # reboot
```

✅ `ld` on the R69 (2026-08-14) · 🟡 H96 Max, and everything past `db`, untested here.

## Credits

Original RK3518 bring-up method by
**[juliovendramini/rk3518_armbian](https://github.com/juliovendramini/rk3518_armbian)**.

Scripts MIT · device trees GPL-2.0+/MIT (derived from Rockchip DTs) · `factory_idbloader.bin` and
`u-boot.itb` are Rockchip/U-Boot/ATF blobs under their own licenses.
