# CVBS out on RK3528: what it took, and what is still open

`tve@ff880000` is `okay` in every factory blob here and wired to VP1, but **no kernel Armbian ships
contains the driver that binds it**. A kernel built with `CONFIG_ROCKCHIP_DRM_TVE=y` produces a
picture and the jack's analog audio alongside it.

Not board data — `tve@ff880000` is identical in `rk3528.dtsi` and in all three trees here. A board
with no AV jack disables the node; the boards that have one need everything below.

## The two blockers

`ROCKCHIP_DRM_TVE` is `bool` with no `default`, so a savedefconfig that omits it means _off_.
Armbian's `linux-rk35xx-vendor.config` omits it. Resolved against the kernel tree, on the host:

```sh
make -C <kernel> ARCH=arm64 olddefconfig   # after copying the config to .config
grep ROCKCHIP_DRM_TVE <kernel>/.config     # -> # CONFIG_ROCKCHIP_DRM_TVE is not set
```

`rockchipdrm-$(CONFIG_ROCKCHIP_DRM_TVE) += rockchip_drm_tve.o` links the encoder into `rockchipdrm`
itself, so it cannot be a module and cannot be added to a running box — **composite needs a rebuilt
kernel, not an overlay file.**

**wlroots drops every interlaced mode when it builds a connector's mode list**, and both CVBS modes
are interlaced, so a TV connector arrives advertising nothing:

```
[backend/drm/drm.c:1646] Detected modes:
[backend/drm/drm.c:980]  connector TV-1: Modesetting with 720x480 @ 59.710 Hz
```

Nothing is listed, so the compositor selects nothing and the backend synthesises a progressive
720x480 — `DRM_MODE_TYPE_USERDEF`, which composite cannot carry. `wlroots-keep-interlaced-tv-modes`
in the kage tree keeps interlaced modes on `DRM_MODE_CONNECTOR_TV` and leaves every other connector
on the existing path.

## What the tree carries

`rockchip,tvemode = <0x01>` on `tve@ff880000` — NTSC 720x480i preferred, `<0x00>` for PAL. Both
modes stay in the list either way. A board without the property depends on the kernel patch instead.

The property is what decides the standard, because **no `uboot.dts` here has a `tve` node**. Vendor
U-Boot pins `route_tve` to 720x576@50 with overscan before handing over; ours leaves it to the
kernel.

## Verified on the H96 Max, 2026-09-21

`sudo cat /sys/kernel/debug/dri/0/summary` with a 640x480 compositor running:

```
Video Port1: ACTIVE     Connector:TV-1   Encoder: TV-338
Display mode: 720x480i59.94   type[48] flag[1015]
Fixed V: 240 240 243 262
Esmart3-win0: src rect[640 x 480]  dst pos[40, 0] rect[640 x 480]  pitch: 2560
```

`type[48]` is `DRIVER | PREFERRED`, so `rockchip,tvemode` reached the tree. `flag[1015]` is
`PHSYNC | PVSYNC | INTERLACE | DBLCLK`. `Fixed V` halved to 240 is the interlace split; a
progressive mode leaves it at 480.

Analog audio out of the same jack: `card 1: rk3528acodec`, `sai2` → `acodec@ffe10000`. Silent until
`DAC LEFT LINEOUT` and `DAC RIGHT LINEOUT` are raised — both default low and neither persists
without ALSA state. Nothing in the tree or the kernel config needed changing for it.

## What VP1 can drive

`rk3528_vop_video_ports[1].max_output` is `{ 720, 576 }` and `dclk_max` 108 MHz — VP1 exists for
CVBS and nothing else. Its planes are Esmart2 (cursor) and Esmart3 (primary); Esmart0 and Esmart1
are VP0-only, by `layer_sel_id`.

**The `esmart_lb_mode = [02]` graft costs VP1 nothing.** `vop3_ignore_plane()` refuses only Esmart1
in `VOP3_ESMART_4K_2K_2K_MODE`, and Esmart2/Esmart3 lose half their line-buffer width — 2048 px,
still three CVBS lines. HDMI 4K60 and composite do not contend.

No tree here sets `rockchip,plane-mask`, so `bootloader_initialized` stays false and VOP2 assigns
Esmart0 to VP0 and Esmart3 to VP1 by itself.

## Open

**Overscan.** A television crops every edge. A 640x480 image centred in 720x480 is already inset 40
px each side horizontally and **not at all vertically**, so the top and bottom rows are what get
lost. The DRM margin properties are a post-scaler, not a crop — `post_scl_factor` and
`POST_HORIZONTAL_SCALEDOWN_EN(hdisplay != hsize)` — so using them downscales the whole frame through
a filter no plane-level property reaches. For pixel-exact content the answer is a safe-area contract
in content, not compensation in the pipeline. `drm-rockchip-fbdev-inset-console-on-tv` covers the
console only, and leaves every KMS client alone.

**PAL.** `rockchip,tvemode = <0x00>` selects 720x576i50. Never set here; nothing predicts a problem.

**The three `drm-rockchip-*` patches are unbuilt.** `patches/linux-rockchip/README.md` says what
each fixes.

**Default audio output ships, unverified across a reboot.** A TV encoder has no detect line, so "is
the AV cable in" is not knowable; the implementable rule is HDMI when its connector reports
connected, analog otherwise. `rk35xx-output-select` forces the losing connector off and writes
matching sink priorities, before any user session starts.

It does not use ALSA jack state, though the kernel has it: `rockchip,jack-det` is in the tree and
`amixer -c 0 controls` shows `rockchip,hdmi Jack`. PipeWire never sees it — every card is a
`simple-audio-card` with no UCM profile, so all three sinks come up as a generic `analog-output`
port with `availability unknown` and the default-node picker has nothing to skip on. A UCM profile
declaring the port and its `JackControl` would make availability work and make the script
unnecessary; nobody has tried one.

The WirePlumber setting names come from `wpctl settings` on the box; the first three shipped were
guesses and all three were wrong. The names are `node.`-prefixed, and there is no
`device.restore-props`.
