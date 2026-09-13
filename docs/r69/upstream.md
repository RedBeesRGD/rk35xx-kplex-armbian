# What upstreaming the R69 taught us

Both submissions are **closed**: `armbian/build#10440` (board) and `armbian/linux-rockchip#528`
(device tree). The board stays downstream, losing nothing functionally — the DT and board config
install onto a stock Armbian image. Board-independent kernel fixes are still pursued separately.

## The vendor EVB tree is not this board

The box's `compatible` names `rk3528-evb1-ddr4-v10`, so its dts looks like a usable base. It is not:
the normalised property diff is 1419 lines and the substance is silicon binning.

|                             | factory (this box)                 | vendor EVB                    |
| --------------------------- | ---------------------------------- | ----------------------------- |
| lowest CPU OPP              | 1.2 GHz                            | 408 MHz                       |
| second OPP                  | 1.416 GHz                          | 600 MHz                       |
| `opp-microvolt`             | 900 mV, ceiling 1000 mV            | 825 mV, ceiling **1100 mV**   |
| `rockchip,pvtm-voltage-sel` | its own table, CPU and GPU         | different tables              |
| root compatible             | `rk3518-…`, **`rockchip,rk3528a`** | `rk3528-…`, `rockchip,rk3528` |

Two rows are disqualifying. The EVB's OPP table runs a differently-binned part on another board's
DVFS envelope with a 100 mV higher ceiling, against a `scaling_available_frequencies` that must
match the **factory** table. And the EVB declares `rockchip,rk3528`, not `rk3528a` — the string
`librockchip_mpp` substring-matches to pick a codec backend.

## `firmware/` ships a flat tree because includes drift

A file with no includes cannot be changed from outside, so a vendor kernel rebase cannot silently
alter a clock rate, a regulator ramp or an OPP here. An include-based file inherits every such
change without it appearing in its own diff, and the symptoms surface only on hardware. The cost is
that upstream dtsi _fixes_ do not reach us either.

## Bluetooth belongs in `hci_h4`, not a new driver

🟡 Submitted, unmerged (`linux-rockchip#526`). The first attempt was `hci_aic.c`: a new protocol ID
and serdev probe, ~200 lines, ~140 copied from `hci_h4.c`.

H:4 is the Bluetooth spec's UART transport, not an AICSemi thing, and `hci_h4.c` already implements
the whole protocol — what it lacks is a serdev driver, which is why the image runs
`hciattach -s 1500000 <dev> any 1500000 flow nosleep` from a unit. The patch adds that binding to
`hci_h4.c` (probe, `max-speed`, an `of_device_id` table starting `aicsemi,aic8800-bt`) with no new
protocol ID: 76 lines added, none changed.

Checked against the seven serdev drivers already in `drivers/bluetooth/`:

- registration follows `hci_ll`/`hci_mrvl`/`hci_bcm` — `serdev_device_driver_register()` in
  `h4_init()`, then `hci_uart_register_proto(&h4p)`
- the `#ifdef CONFIG_BT_HCIUART_SERDEV` is ours alone and necessary: those three depend on
  `BT_HCIUART_SERDEV` in Kconfig, while `BT_HCIUART_H4` must still build tty-only
- init and oper speed are the same value, matching the proven hciattach line; this chip has no
  baud-change step
- flow control via `serdev_device_set_flow_control(hu->serdev, true)`, as `hci_h5` does — **not**
  `hci_uart_set_flow_control()`, whose `enable` argument is inverted
- no enable GPIO: this board powers the controller from the SDIO side and its node has none

Until it merges the shipped DTB cannot declare the serdev child at all, so the node is carried as a
comment; `r69/dtb.md` records why and the condition that ends it.

## Our U-Boot cannot read `LAN_MAC` at all

✅ Verified against the shipped blob and the build tree. Vendor storage is a Rockchip downstream
driver; we build **mainline**, which has none — `strings` on `firmware/r69/uboot.itb` finds no
`vendor_storage`, no `LAN_MAC`, no `rockchip_set_ethaddr`.

So `end0` is handed `local-mac-address` from mainline's `rockchip_setup_macaddr()`
(`arch/arm/mach-rockchip/board.c`): SHA256 of the OTP `cpuid#`, first six bytes, multicast bit
cleared and the LA bit set. On the R69 that is `36:c8:c4:28:e4:08` against a label
`LAN_MAC = c4:2a:fe:10:51:77`. It is **deterministic per box**, not random — `net_random_ethaddr()`
survives only as an `eth-uclass.c` fallback that is never reached, because `ethaddr` is already set
by then.

`rk35xx-mac-pin` exists to correct that in userspace. Two things would remove the need, neither
free:

| Route                                             | Blocker                                                                             |
| ------------------------------------------------- | ----------------------------------------------------------------------------------- |
| pre-set `ethaddr` (the function honours it first) | `CONFIG_ENV_IS_NOWHERE=y` — no persisted env to set it in                           |
| teach our U-Boot to read vendor storage           | mainline has no such driver; means carrying a patch                                 |
| switch to Rockchip's vendor U-Boot                | BL31 v1.17 (`Unknown SoC`), and it ships `# CONFIG_ROCKCHIP_SET_ETHADDR is not set` |

The kernel side reads the **eMMC** store always (`rk_emmc_transfer()` → `this_card`, set for eMMC
only), which is why `rk35xx-vendor-storage` gets the label address whatever the box booted from.

## Addresses the store does not hold

✅ `WIFI_MAC` and `BT_MAC` are empty on every box here, so the Wi-Fi driver invents one per boot.
`rk35xx-mac-pin` derives instead — locally administered, from `serial-number` (which
`rockchip-cpuinfo` folds from the 16-byte `otp_id: id@a` cell on `otp@ffce0000`), identical every
boot and from either medium, writing nothing.

`WIFI_GENERATE_RANDOM_MAC_ADDR` must stay off: it wins over any derivation and hands back an
`eth_random_addr()` `02:…` that only looks stable if `rk_vendor_write()` lands — and
`emmc_vendor_write()` ignores the eMMC transfer's return value, so that write can fail silently.

## Still open

1. Does `hci0` survive being brought up at probe time, before the SDIO side has loaded firmware?
   Gates whether `#526` is enough on its own.
2. Does dropping `interrupts` from pwm0–2 let the in-kernel IR driver bind? All four channels share
   `GIC_SPI 53` by Rockchip's own design, the IRQ is optional in the PWM driver, and nothing on this
   board uses capture or oneshot. Would retire the `initcall_blacklist` workaround.
