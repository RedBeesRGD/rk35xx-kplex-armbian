# HS86 Mini 13 — board details

Sold as the "HS86 Mini 13". Its PCB is its own, not a revision of the R69 or H96 Max: different
silkscreen, an eMCP (DRAM and eMMC in one package), and the RK3528 proper rather than the RK3518.

## Identity — check yours matches before flashing

|               |                                                                           |
| ------------- | ------------------------------------------------------------------------- |
| Name          | **"HS86 Mini 13"**                                                        |
| SoC           | **RK3528** — factory tree `rockchip,rk35x8-hugsun-x88pro-ddr4-v10`        |
| RAM / storage | eMCP: 2 GB (**~1.9 GB usable**) · 14.7 GB eMMC · microSD                  |
| Runs from     | microSD; factory Android left on the eMMC                                 |
| Wi-Fi / BT    | **Seekwave SWT6621S** — SDIO `1ffe:6621`, chip id `SV6160LITE`            |
| Ethernet      | 10/100, RK630 PHY                                                         |
| LEDs          | `power` gpio4 C1 · `standby` gpio4 B3 · IR gpio4 B7 — all **active-high** |
| Front panel   | HT1628 LED driver, bit-banged (`skykirin_led`) — no Linux driver          |
| RTC           | HYM8563 on `i2c@ffa58000`, address `0x51`                                 |
| PCB marking   | `RK35X8-EMCP-347-01-V1.0`                                                 |

## Status

| Hardware                       | State | Evidence                                                   |
| ------------------------------ | ----- | ---------------------------------------------------------- |
| Boot from SD                   | ✅    | with the H96 Max image: its loader pair and DTB            |
| Ethernet 10/100                | ✅    | `end0` 100Mbps/Full on the H96 Max DTB — node identical    |
| USB 2.0 keyboard               | ✅    | `usb 4-1` enumerated on the H96 Max DTB                    |
| Composite video                | ✅    | reported working on the H96 Max DTB — `tve` node identical |
| AV-jack analog audio           | ✅    | reported working on the H96 Max DTB — `acodec` identical   |
| Output select at boot          | ✅    | reported working on the H96 Max DTB                        |
| Wi-Fi / BT on the H96 Max DTB  | ❌    | `GPIOOUT:108 cannot be operated` — see `dtb.md`            |
| Wi-Fi / BT, factory power path | ❌    | enable held low; no SDIO card — see `dtb.md`               |
| Wi-Fi, pwrseq power path       | ✅    | `wlan0` up and connected, reported 2026-09-25              |
| Bluetooth                      | ❓    |                                                            |
| Other USB port                 | ❓    | VBUS is gpio4 B4 here, B5 on the H96 Max                   |
| RTC                            | ❓    |                                                            |
| IR remote keymap               | 🟡    | factory `ir_key*` tables carried unchanged                 |
| LEDs                           | 🟡    | inverted on the H96 Max DTB, which drives them active-low  |
| VP9 hardware decode            | ❓    | tree says `rk3528`, which MPP treats as having no VP9      |
| Serial console                 | ❓    | pads not located                                           |
| Maskrom button in U-Boot       | ❓    | borrows the H96 Max `uboot.itb`                            |

## Known gaps

- **U-Boot is the H96 Max's.** A per-board `uboot.itb` needs this box's factory U-Boot DTB, from the
  eMMC `uboot` partition (`mmcblk*p2`, 4 MiB) → `stock/hs86-mini13/uboot.dtb`.
- **Seekwave NV is the H96 Max's** (`STANDALONE_FDD`). The factory NV sits in `/vendor` inside
  `super`; `cmp` it against both shared variants.
- **Which of the five DTBs in `boot` is this board's** is inferred, not read from the bootloader —
  `dtb.md` has the reasoning.
