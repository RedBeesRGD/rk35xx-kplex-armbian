# HS86 Mini 13 — `board.dts` changes

Base: the box's factory Android DTB, carved from the eMMC `boot` partition
(`stock/hs86-mini13/board.dtb`, `rockchip,rk35x8-hugsun-x88pro-ddr4-v10`). Edit
`firmware/hs86-mini13/board.patch`, then `./build-board-dts.sh hs86-mini13`; never edit
`firmware/hs86-mini13/board.dts`.

## Which blob is the board's

`boot` holds five DTBs (`stock/hs86-mini13/boot-dtbs/` keeps the other four). The first, at
`0x1fc7800`, is taken:

| Offset      | Compatible                               | Wi-Fi wiring             |
| ----------- | ---------------------------------------- | ------------------------ |
| `0x1fc7800` | `rockchip,rk35x8-hugsun-x88pro-ddr4-v10` | `sdio1`, enable gpio3 B2 |
| `0x23d6000` | `rockchip,rk3518-hugsun-x88pro-ddr4-v10` | `sdio1`, enable gpio3 B2 |
| `0x23edd2a` | `rockchip,rk3528-hugsun-x88pro-ddr4-v10` | `sdio0`, gpio1           |
| `0x2407537` | `rockchip,rk3528-hugsun-x88pro-ddr4-v10` | `sdio0`, gpio1           |
| `0x2420bb6` | `rockchip,rk3528-hugsun-x88pro-ddr4-v10` | `sdio0`, gpio1           |

- The Seekwave chip enumerates on this box with its enable on gpio3 B2, which rules out the three
  `sdio0` blobs.
- Of the two left, `0x23d6000` is for an RK3518; this SoC is an RK3528, and `rk35x8` is the PCB's
  own silkscreen prefix.
- It is also the first `d00dfeed` in the partition, where the other boards' trees were found.

## Changes

| Node                | Change                                                  | Why                                                           |
| ------------------- | ------------------------------------------------------- | ------------------------------------------------------------- |
| `/` (root)          | `model` → `HS86 Mini 13 RK35X8-EMCP-347-01-V1.0`        | the factory string names the X88PRO reference design          |
| `reboot-mode`       | `mode-maskrom` added                                    | 🟡 `reboot maskrom` from the OS; factory SPL reads it         |
| `gpu@ff700000`      | `interrupt-names`/`clocks`/`clock-names` → lima style   | Armbian uses mainline `lima`                                  |
| `vop@ff840000`      | `esmart_lb_mode` `[03]` → `[02]`                        | 🟡 4K line buffer for Esmart0                                 |
| `tve@ff880000`      | `rockchip,tvemode = <0x01>` added                       | NTSC 720x480i preferred                                       |
| `serial@ff9f0000`   | `status` → `okay`, `pinctrl-0 = <&uart0m0_xfer>`        | `ttyS0` console, as `BOARD_SERIALCON`'s default expects       |
| `fiq-debugger`      | `status` → `disabled`                                   | frees `ff9f0000` for `ttyS0`                                  |
| `pwm@ffa90030` (IR) | `remote_support_psci` `0` → `1`                         | IR as ATF wake source                                         |
| `watchdog@ffac0000` | `status` → `okay`                                       | `/dev/watchdog` for systemd's `RuntimeWatchdogSec`            |
| `mmc@ffc30000` (SD) | `sd-uhs-sdr12/25/50/104` **removed**                    | SD is this box's root; the H96 Max lost it on warm reset      |
| `wifi-en`           | `regulator-always-on` added                             | 🟡 no consumer, so it is switched off as unused ~30 s in      |
| `gpio-leds`         | `pwr-green`/`pwr-red` → `power`/`standby`               | the shared LED hooks' names                                   |
| `gpio-leds/power`   | `retain-state-suspended`, `retain-state-shutdown` added | the hooks, not the LED core, own it across sleep and poweroff |
| `chosen`            | **removed**                                             | u-boot supplies bootargs; the factory string names `ttyFIQ0`  |

Everything else is factory. `compatible` is left alone: `rockchip,rk3528` already names the SoC to
MPP, and our payload ships no board-keyed Seekwave firmware.

## Why the H96 Max tree breaks Wi-Fi here

Same radio, different wiring. The H96 Max tree hands the Seekwave driver `gpio_chip_wake` = gpio3 C4
(108); this board's factory tree names that pin `wifi_reset` and only holds it high by pinctrl. The
chip's firmware reports the wake line dead and the boot aborts:

```
[SKWSDIO ERROR] skw_sdio_chk_cp_gpio_cfg: GPIOOUT:108 cannot be operated, pls check gpio num or hw connect!!.
sv6160lite: probe of seekwcn_boot failed with error -1
```

The factory `seekwcn_sv6160lite` node sets no GPIOs, so `skw_sdio_chk_cp_gpio_cfg()` takes its
`gpio_in and gpio_out no config` exit instead. The oops that follows at `hci_power_off` is `skwbt`
closing a port the failed boot never set up — a driver bug reached only through that failure.

## The `wifi-en` graft

Power comes from `wifi-en`, a `regulator-fixed` on gpio3 B2 with `regulator-boot-on`. Nothing names
it as a supply — `sdio-pwrseq` carries only its pinctrl — and without `regulator-always-on`,
`of_get_regulation_constraints()` grants `REGULATOR_CHANGE_STATUS`, so `regulator_late_cleanup()`
switches it off. Drop the graft if Wi-Fi survives a minute without it.

## Tried and reverted

None yet.
