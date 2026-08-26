# The bootloader pair

Two blobs at two sectors, from two different origins. Write them **after** the OS image — write them
first and the image's own loader overwrites them.

| Sector | Blob                                     | Origin                                  |
| ------ | ---------------------------------------- | --------------------------------------- |
| 64     | `firmware/<board>/factory_idbloader.bin` | carved from that box's eMMC — **kept**  |
| 16384  | `firmware/common/u-boot.itb`             | built here by `build-uboot.sh` — shared |

## Why the idbloader stays factory

Its DDR tuning is the only one proven stable on this DRAM die; public rkbin DDR blobs are a lottery.
The failure is a random `Synchronous Abort` whose `far` register holds ASCII text — RAM corruption,
not a code bug. Carve it per board; it is the one bootloader file that is not shared.

A backup recovers only the DDR half, so `build-rktools.sh` builds a maskrom USB loader per board
(that board's DDR init + Rockchip's `usbplug`). Build it natively — USB does not reach a container
on macOS.

## Why `u-boot.itb` is built rather than taken

No third-party prebuilt, every input pinned, the build reproducible.

| Input  | Pin                                                    |
| ------ | ------------------------------------------------------ |
| U-Boot | mainline tag `v2026.04`, `generic-rk3528_defconfig`    |
| BL31   | `rk3528_bl31_v1.21.elf` from `rkbin`, pinned by commit |
| TPL    | `rk3528_ddr_1056MHz_v1.13.bin` — build input only      |

- **BL31 v1.20 is the floor.** RK3518 support landed there; older ATF stops at `Unknown SoC`.
  Armbian's own `linux-u-boot-rock-2f-vendor` builds against `rk3528_bl31_v1.17.elf` — its
  `u-boot-metadata-target-1.sh` says so — which is why that loader cannot boot these boxes.
- **Mainline, not the vendor tree.** Rockchip maintains a downstream fork on an old mainline base,
  and Armbian's `rock-2f-vendor` package is a build of it: `CONFIG_ANDROID_BOOTLOADER=y`,
  `CONFIG_ANDROID_AVB=y`, `CONFIG_CMD_BOOT_ANDROID=y`, and `SPL_FIT_GENERATOR=make_fit_atf.sh`, long
  gone from mainline. Its `bootcmd` runs `boot_android`/`bootrkp`, finds `/boot/boot.scr`, bails and
  falls through to PXE. Mainline's `generic-rk3528` boots Armbian through `distro_bootcmd`.
- **Switching to it would not fix the MAC.** It does carry vendor storage
  (`CONFIG_ROCKCHIP_VENDOR_PARTITION=y`, `vendor_storage_init` in the blob), but Armbian's defconfig
  has `# CONFIG_ROCKCHIP_SET_ETHADDR is not set` — the option that would turn `LAN_MAC` into
  `ethaddr`. Reading the store and using it for the MAC are two separate switches.
- **No OP-TEE.** The FIT carries ATF + U-Boot only. BL31 prints one benign
  `No OPTEE provided … opteed_fast`. Re-add with `TEE=` and `rk3528_bl32_v1.06.bin` if ever needed.
- **`ROCKCHIP_TPL=` never reaches the artifact.** Binman assembles TPL+SPL+FIT as one image; only
  the FIT is extracted and the built idbloader discarded. Reproducibility rests on the U-Boot and
  BL31 pins alone.
- **`rkbin` is pinned to one commit shared with `build-rktools.sh`.** Bump both together.

## Rebuilding

```sh
./build-uboot.sh            # Linux; writes firmware/common/u-boot.itb, scratch in uboot-build/
./build-uboot-finch.sh      # macOS; same build in a native arm64 Debian container

strings -a firmware/common/u-boot.itb | grep -E 'bl31-v|fdt-rk3528'   # identify a suspect blob
# bl31-v1.21 / fdt-rk3528-generic

sudo dd if=firmware/common/u-boot.itb of=/dev/<sd> bs=512 seek=16384 conv=notrunc; sync
```

Smoke-test before trusting it: the factory idbloader at sector 64 stays put, and it must reach an
Armbian login over serial.

## What rebuilding cannot fix

**The R69's 1.5 GB ceiling is the factory TPL's, not U-Boot's.** The TPL trains two 1 GB
chip-selects but hands on an `ATAG_DDR_MEM` describing two banks totalling 1.5 GB with nothing above
them. Proven, not assumed: Rockchip's vendor U-Boot sets `CONFIG_BIDRAM=y` — the path that _adds_
any extended-top region the TPL flags — and its `bdinfo` printed those same two banks with
`gd->ram_top_ext_size == 0`. The TPL banner, stock `/proc/iomem` and the stock DTB `/memory` node
all agree.
