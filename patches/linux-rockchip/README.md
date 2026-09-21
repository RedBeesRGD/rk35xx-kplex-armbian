# linux-rockchip — kernel patches

Board-independent fixes for `armbian/linux-rockchip`, the vendor kernel these images run. They are
**not applied by this repo**: Armbian's `patch/kernel/<family>/` and `userpatches/kernel/<family>/`
only run when you build the kernel, and an overlay box takes its kernel from `apt`. They live here
so the work survives, and because the bugs they describe are visible on both boards.

| Patch                                    | PR            | Fixes                                                                       |
| ---------------------------------------- | ------------- | --------------------------------------------------------------------------- |
| `input-remotectl-share-pwm-irq`          | [#523][523]   | IRQ selection and sharing on PWM v1 — the IR receiver                       |
| `net-stmmac-skip-absent-mdio-reset-gpio` | [#524][524]   | a WARN + ~416 lines of trace at every boot, on both boards                  |
| `net-dwmac-rk-prefer-vendor-storage-mac` | [#525][525]   | `end0` coming up on a derived address instead of the label one              |
| `bluetooth-hci-h4-serdev`                | [#526][526]   | serdev binding for `hci_h4`, so BT needs no `hciattach` unit                |
| `wireless-aic8800-stable-mac`            | [#527][527]   | the AIC8800 inventing a fresh MAC each boot                                 |
| `mmc-dw-mmc-rockchip-per-host-inherit`   | not submitted | `static bool inherit` in `dw_mci_v2_execute_tuning()` — **not needed here** |
| `drm-rockchip-tve-init-preferred-mode`   | not submitted | an uninitialised `preferred_mode` when `rockchip,tvemode` is absent         |
| `drm-rockchip-tve-reject-non-cvbs-modes` | not submitted | a synthesised progressive mode accepted by a CVBS-only encoder              |
| `drm-rockchip-fbdev-inset-console-on-tv` | not submitted | a console whose edges a television overscans off the tube                   |

[523]: https://github.com/armbian/linux-rockchip/pull/523
[524]: https://github.com/armbian/linux-rockchip/pull/524
[525]: https://github.com/armbian/linux-rockchip/pull/525
[526]: https://github.com/armbian/linux-rockchip/pull/526
[527]: https://github.com/armbian/linux-rockchip/pull/527

**#524 is worth more than the rest combined for log hygiene.** One WARN at probe emits its call
trace and register dump — ~416 lines, 78% of all err/warn on the R69 and 82% on the H96 Max.

**The three `drm-rockchip-*` patches target a driver that now runs here, and none of them has been
built.** `ROCKCHIP_DRM_TVE` is off in `linux-rk35xx-vendor`; a kernel built with it produces
composite, so these bugs are reachable rather than theoretical, but each is still read out of the
source. `docs/todo/rk35xx-cvbs-tve.md` holds the state and what a build has to show.

The two `tve` patches cannot touch HDMI: `rockchip_drm_tve.c` drives composite and nothing else.
`drm-rockchip-fbdev-inset-console-on-tv` is scoped by connector type and switched off with
`rockchipdrm.fbdev_tv_margin=100`.

**`mmc-dw-mmc-rockchip-per-host-inherit` stays unsubmitted: neither board can trigger the bug, and
neither can be made to.** It needs two enabled `dw_mci` controllers both taking the v2 tuning path,
contending over a function-scope static.

|         | `mmc@ffc20000` SDIO             | `mmc@ffc30000` SD                     |
| ------- | ------------------------------- | ------------------------------------- |
| R69     | v2-tuning, UHS — **tunes**      | v2-tuning, UHS stripped — never tunes |
| H96 Max | no v2-tuning, UHS — non-v2 path | v2-tuning, UHS stripped — never tunes |

One v2 consumer each, so no contention. Restoring `sd-uhs-*` would not change it either: the R69's
SD has no `vqmmc-supply` and so no 1.8 V switch to run UHS with at all, and the H96 Max's SDIO does
not declare `use-v2-tuning`, so it stays on the non-v2 path however its SD is configured. The bug is
real — a per-host decision in a static is wrong regardless — but we cannot make it fire, and sending
it unverified would be publishing a recipe we have not run.

To build a kernel with these, copy into `patch/kernel/rk35xx-vendor-6.1/` or
`userpatches/kernel/rk35xx-vendor-6.1/` of an `armbian/build` checkout; both are applied
automatically.
