# CVBS out on RK3528: the TVE driver is not in the Armbian kernel

`tve@ff880000` is `okay` in every factory blob here and wired to VP1, but **no kernel these boxes
run has ever contained the driver that binds it**. The AV jack was marked 🟡 on the strength of the
tree alone; it is ❓, and was never anything else.

Not board data — `tve@ff880000` is identical in `rk3528.dtsi` and in all three trees here. The two
boards with a jack (R69, H96 Max) are both affected; the 3518D has no jack and disables the node.

## The finding

`ROCKCHIP_DRM_TVE` is `bool` with no `default`, so a savedefconfig that omits it means _off_.
Armbian's `linux-rk35xx-vendor.config` omits it. Resolved against the kernel tree, on the host:

```sh
cp build/config/kernel/linux-rk35xx-vendor.config linux-kplex/.config
make -C linux-kplex ARCH=arm64 olddefconfig
grep ROCKCHIP_DRM_TVE linux-kplex/.config      # -> # CONFIG_ROCKCHIP_DRM_TVE is not set
```

`rockchipdrm-$(CONFIG_ROCKCHIP_DRM_TVE) += rockchip_drm_tve.o` links the encoder into `rockchipdrm`
itself, so it cannot be a module and cannot be added to a running box — **CVBS needs a rebuilt
kernel, not an overlay file.** An `apt` kernel will not have it.

`card0-TV-1 connected` in `stock/h96max-3518d/display.txt` is the factory Android kernel, which sets
`CONFIG_ROCKCHIP_DRM_TVE=y`. It is not evidence about Armbian.

## What ships now

| Where                                     | Change                                        |
| ----------------------------------------- | --------------------------------------------- |
| `build/config/kernel/linux-rk35xx-vendor` | `CONFIG_ROCKCHIP_DRM_TVE=y`                   |
| `firmware/h96max/board.patch`             | `rockchip,tvemode = <0x01>` on `tve@ff880000` |
| `patches/linux-rockchip/`                 | `drm-rockchip-tve-init-preferred-mode.patch`  |

The config line survives `make savedefconfig`, so the fork's kernel-config rewrite pass keeps it.

`rockchip,tvemode` picks which mode carries `DRM_MODE_TYPE_PREFERRED`: `00` is PAL 720x576i, `01` is
NTSC 720x480i. Both stay in the connector's mode list whichever is set. The R69 does not carry the
property yet.

The property is what decides the standard here because **our U-Boot never touches `tve`** — no
`uboot.dts` here has the node. Vendor U-Boot pins `route_tve` to 720x576@50 with overscan before
handing over; ours leaves the mode to the kernel.

## The driver bug behind the property

`tve_parse_dt()` and `tve_parse_dt_legacy()` both declare `int ret, val` and assign
`tve->preferred_mode` twice when `rockchip,tvemode` is absent — first `0`, then `val`, which
`of_property_read_u32()` never wrote. `rockchip_tve_get_modes()` compares the result against the
`cvbs_mode[]` index, so a stack-garbage value marks **neither** mode preferred and userspace takes
whichever it enumerates first. Every vendor RK3528 tree here omits the property.

The patch assigns `val` in the absent branch. It is not applied by this repo; the DT graft makes it
moot on the H96 Max, and the R69 needs one or the other.

## What VP1 can drive

`rk3528_vop_video_ports[1].max_output` is `{ 720, 576 }` — VP1 exists for CVBS and nothing else. Its
planes are Esmart2 (cursor) and Esmart3 (primary); Esmart0 and Esmart1 are VP0-only, by
`layer_sel_id`.

**The `esmart_lb_mode = [02]` graft does not cost VP1 anything.** `vop3_ignore_plane()` refuses only
Esmart1 in `VOP3_ESMART_4K_2K_2K_MODE`, and Esmart2/Esmart3 lose half their line-buffer width — 2048
px, still three times a CVBS line. HDMI 4K60 and CVBS do not compete.

No tree here sets `rockchip,plane-mask`, so `bootloader_initialized` stays false and VOP2 assigns
planes itself: Esmart0 to VP0, Esmart3 to VP1.

## Untested — what to do with a box

Needs a kernel built from the fork, installed over the `apt` one, and a TV with a composite input.

```sh
ls /sys/class/drm/                             # expect card0-TV-1 alongside card0-HDMI-A-1
dmesg | grep -i tve
sudo modetest -M rockchip -c                   # expect 720x480i and 720x576i on the TV connector
sudo grep dclk_vp1 /sys/kernel/debug/clk/clk_summary
```

Then confirm, in order: a picture on the jack at all; the right standard (`01` should give 480i);
HDMI still correct with both connected; and whether a board whose recovery button sits recessed
inside the AV socket can still be poked with a plug in it.

`card0-TV-1` will read `connected` with nothing plugged in — TVE has no detect line.

## Analog audio is a separate question

The jack carries composite video **and** analog audio. `acodec` and its sound card are untouched
here and the AV jack's audio path has never been traced on any board. Nothing above tests it.
