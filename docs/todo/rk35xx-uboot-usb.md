# Our U-Boot has no USB, and on an SD-less box that is a design fault

Family-wide. Opened 2026-09-05 after the H96 Max 3518D became unreachable mid-flash: our U-Boot
booted, could not finish booting a partially written rootfs, and — having no USB — presented nothing
on the bus at all. Recovery needed serial.

## Scope it per board: USB is required only where there is no SD

Per-board U-Boot makes this selective, which is the point — a board that does not need USB should
not carry the risk of it.

| Change                       | R69 / H96 Max                                       | H96 Max 3518D                                              |
| ---------------------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| USB PHY + controllers + VBUS | optional — SD already gives boot media and recovery | **required** — the only removable path                     |
| `bootcount` / `altbootcmd`   | useful                                              | **most valuable here** — no button access with the case on |

On a board with an SD slot, a bad flash is answered by pulling the card and writing it on the host,
so `rockusb`/`ums` are convenience. On an SD-less box they are the whole story: no card to pull, and
with the case closed no button either.

A host config for the 3518D needs **EHCI and OHCI, not just XHCI/DWC3**. The sockets are mapped: the
**USB-C is the OTG port** (`dwc3`/`xhci`, where the box enumerates as `2207:350c`) and the **USB-A
is the `ehci`/`ohci` pair**, USB 2.0 only. So the gadget side — rockusb, `ums` — lands on USB-C, but
a boot stick in the obvious socket needs the EHCI/OHCI drivers.

## The USB nodes are per board too, and they fail silently

Measured across the three factory kernel trees:

- **The OTG regulator GPIO differs**: pin 18 on the R69, pin 12 on both H96 Max boards. A shared
  node is wrong for one of them, and it fails _silently_ — the controller probes, the port simply
  has no VBUS.
- **Ethernet is identical in the DT and different in hardware**: all three inherit the EVB's
  `okay`/rmii, but the 3518D has no PHY (`phy_poll_reset failed: -110`).

The factory **U-Boot** DT has no USB controller at all — only `usb2-phy@ffdf0000` with an
`otg-port`, plus `phy@ffdc0000` combphy. Rockchip's downstream gadget is hardcoded rather than
DT-probed, so the PHYs come free and the controllers must come from the kernel tree.

## The problem

Our U-Boot is mainline `v2026.04` + `generic-rk3528_defconfig`, which carries
`# CONFIG_USB is not set` and `CONFIG_NO_NET=y`. Once it runs, **serial is the only interface**.

The factory U-Boot is self-rescuing: it serves rockusb, so `rkdeveloptool` can always reach the box.
Ours cannot. We replace a bootloader that could rescue itself with one that cannot.

On a box with a card slot, losing rockusb is inconvenient — boot an SD instead. On one without, the
box goes off the bus entirely and only serial is left. The 3518D is the board with no slot.

## Why it is not a config flip

Mainline's `rk3528.dtsi` (`dts/upstream/src/arm64/rockchip/`, 1178 lines) **does not describe USB**.
Its only mentions are two QoS node names, `qos_usb2host` and `qos_usb3otg`, plus two references to
them. There is no controller and no PHY, which is why the defconfig disables USB — nothing would
bind.

The factory tree has all ten nodes, so the definitions are in hand: `dwc3@fe500000` with `usbdrd30`,
`usb@ff100000` (EHCI), `usb@ff140000` (OHCI), `usb2-phy@ffdf0000` with its `otg-port` and
`host-port`, and `combphy@ffdc0000`. See `stock/h96max-3518d/board.dts`.

Every driver is already in-tree: `USB_XHCI_DWC3`, `USB_DWC3_GENERIC`, `USB_FUNCTION_ROCKUSB`,
`CMD_ROCKUSB`, `CMD_USB_MASS_STORAGE`, `PHY_ROCKCHIP_INNO_USB2`.

So the work is a **small DT port** into the per-board tree, plus the Kconfig symbols — not a port of
anything hard. The controller nodes are SoC-level and can be shared by all three boards; the
regulators that give them VBUS are not, and belong per board.

## What it would buy, in order of value

1. **`rockusb`** — restores the rescue the factory bootloader had. The 2026-09-05 stuck state could
   not have happened.
2. **`ums`** — expose the eMMC as a USB block device. Backup and flash become plain `dd` at full
   speed: no `rkdeveloptool`, no chunking, no 32 MiB `Loader` cap, no thermal babysitting. This
   alone would have turned a whole evening of chunked transfers into two commands.
3. **USB host + storage** — boot from a USB stick, which is the SD-slot substitute this board
   otherwise lacks, and the only cheap way to iterate on a DTB without writing eMMC.

## The 32 MiB cap does not exist in mainline

Worth stating plainly, because it inverts the trade-off: **mainline's `f_rockusb.c` has no read
limit.** 932 lines, zero mentions of `READ_LIMIT` or `0xCC`. `RKUSB_READ_LIMIT_ADDR` is a
Rockchip-downstream addition, which is why the _vendor_ U-Boot silently truncates dumps at 32 MiB
and mainline would not.

So enabling rockusb in our build does not merely restore what the factory bootloader offered — it
gives a **better** Loader mode than the box shipped with, with no patch to maintain.

## The config is already written, on the same SoC

`radxa-e20c-rk3528_defconfig` is the template — same SoC, and it enables the whole set:

```
CONFIG_USB=y                         CONFIG_USB_GADGET=y
CONFIG_USB_XHCI_HCD=y                CONFIG_USB_GADGET_DOWNLOAD=y
CONFIG_USB_DWC3=y                    CONFIG_USB_FUNCTION_ROCKUSB=y
CONFIG_USB_DWC3_GENERIC=y            CONFIG_CMD_ROCKUSB=y
CONFIG_USB_EHCI_HCD=y                CONFIG_CMD_USB=y
CONFIG_USB_EHCI_GENERIC=y            CONFIG_CMD_USB_MASS_STORAGE=y
CONFIG_PHY_ROCKCHIP_INNO_USB2=y      CONFIG_DM_REGULATOR_GPIO=y
CONFIG_PHY_ROCKCHIP_NANENG_COMBOPHY=y
```

Both PHY drivers match nodes this SoC actually has — `INNO_USB2` for `usb2-phy@ffdf0000`,
`NANENG_COMBOPHY` for `combphy@ffdc0000`. `DM_REGULATOR_GPIO` is what drives `vcc5v0_host`/`_otg`.
Radxa omits OHCI; add `USB_OHCI_HCD` + `USB_OHCI_GENERIC` for the full-speed half of the USB-A port.

Note it also carries `CONFIG_CMD_ADC`, `CONFIG_BUTTON` and `CONFIG_BUTTON_ADC` — none of which the
download key needs, since `rockchip_dnl_key_pressed()` reads the channel itself.

## Falling back to rockusb needs three layers, not one

`bootcmd = "bootflow scan -lb; rockusb 0 mmc 0"` only helps when `bootflow scan` **returns**. If the
kernel loads and U-Boot hands off, U-Boot never runs again — so a box that boots and then dies in
Linux is still unreachable, which is the case that stranded the 3518D.

| Failure                                    | Covered by                                                   |
| ------------------------------------------ | ------------------------------------------------------------ |
| No bootable media, `bootflow scan` returns | `bootcmd = "bootflow scan -lb; rockusb 0 mmc 0"`             |
| **Boots, Linux never comes up healthy**    | `bootcount` + `bootlimit` + `altbootcmd = "rockusb 0 mmc 0"` |
| Linux is up, you want back in              | boot-mode register `0x5242c301` (`reboot loader`)            |

U-Boot ships the middle one in `drivers/bootcount/`, with `common/autoboot.c` reading `altbootcmd`.
Userspace clears the counter once healthy; after N failures U-Boot runs `altbootcmd` instead. **No
button, no serial, no case open.**

`BOOTCOUNT_SYSCON` into a GRF scratch register is the right backend: it survives the warm/watchdog
reset we care about and clears on power loss, so unplugging stays a clean slate.

**Dependency that is easy to miss:** for the count to advance, a hung kernel has to reset. That
needs U-Boot to **autostart the watchdog** before handing off — the DTB graft plus systemd only
covers the window after systemd starts, which is too late for a kernel that never gets there.

**Residual gaps:** a hard hang with no watchdog running, and the reboots before the limit is
reached. Neither is solvable in the bootloader alone, but it turns "open the case and wire serial"
into "wait for three reboots".

## Open questions before doing it

- **SPL size.** `CONFIG_SPL_MAX_SIZE=0x40000`; adding USB to U-Boot proper should not touch SPL, but
  confirm the FIT still fits where `build-image.sh` writes it.
- **Does `ums` reach the eMMC** on this SoC, or only an SD? Untested.
- **Upstreamability.** rk3528 USB nodes are missing from mainline entirely. Adding them is
  SoC-level, not board-level, so unlike a board DT it benefits every rk3528 user and is worth
  sending upstream.

## Interim

**Until this is done, never write to an SD-less box without serial attached.**
