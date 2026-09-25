# HS86 Mini 13 — worklog

## 2026-09-25 — bring-up from an SD boot, no serial, no Android shell

The H96 Max H313 went off sale; this box replaces it. It was first booted from the H96 Max SD image
unchanged. Composite, AV audio and output selection worked; Wi-Fi did not, and one boot oopsed in
`skwbt`.

**It is not an R69.** The Wi-Fi was assumed to be the R69's AIC8800 from the IR jack and case.
`/sys/bus/sdio/devices` says `1ffe:6621` — the H96 Max's Seekwave — and the PCB reads
`RK35X8-EMCP-347-01-V1.0`, not `XR821_V1.1`.

Evidence was read off the eMMC while booted from SD; nothing was written to it and no full dump
exists, since the box will not be migrated. `collect-hs86.sh` took the `boot` partition's DTBs, the
idbloader at sector 64, `lsblk`, `dmesg`, SDIO ids. Five DTBs in `boot`; the choice is in `dtb.md`.
The idbloader is `RKNS` with DDR blob `v1.13` (the H96 Max's is `v1.11`).

Node diff against the H96 Max factory tree: `tve`, `acodec`, HDMI and `ethernet@ffbd0000` match,
which is why the H96 Max image worked. It differs in the Wi-Fi/BT wiring, LED polarity (active-high
here), USB host VBUS (gpio4 B4, not B5), an HYM8563 RTC, an HT1628 front panel, and CPU OPPs to 2016
MHz.

Wi-Fi cause, from the pinned driver source: the H96 Max tree's `gpio_chip_wake` lands on a pin this
board's factory tree calls `wifi_reset`. `dtb.md` has it.

`firmware/hs86-mini13/` built from the factory tree plus the H96 Max grafts, a `wifi-en`
`regulator-always-on`, and the LED rename with `retain-state-*` added to `power`, which the factory
left off. Round-trip clean; the patched tree differs from factory in exactly the listed nodes.

U-Boot is borrowed from the H96 Max (it booted this box); the factory U-Boot DTB was not collected.

**Nothing from this directory has run on the box yet.**
