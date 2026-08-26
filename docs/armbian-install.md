# `armbian-install` and the factory reserved window

On Rockchip boxes the first 16 MiB of eMMC is a layout, not spare space; `armbian-install` clears it
to lay down partitions.

**A full eMMC backup is mandatory before any migration.** Upstream preserves the two factory stores
that nothing can recreate — that is the whole of the protection. Every other sector in the first 16
MiB is still overwritten, and nothing restores it.

**Merged is not shipped.** The R69 lost its window on 2026-08-18, after the merge, because the image
on the card predated it. Until a release carries the fix, assume the installer zeroed 7168–16383 and
put them back from the dump.

## The layout

Armbian's own `rockchip64_common.inc` writes this map when it builds an SPI loader image, and the
same map applies to eMMC:

| Sectors     | Armbian name | Holds                                                    | Survives the installer    |
| ----------- | ------------ | -------------------------------------------------------- | ------------------------- |
| 64–7167     | `idbloader`  | DDR init + SPL                                           | ❌ zeroed, then rewritten |
| 7168–7679   | `vnvm`       | vendor storage, tag `DVKR` — `LAN_MAC`, `BT_MAC`, serial | ✅ kept                   |
| 7680–8191   | `reserved*`  | includes `uboot_env` at 8128–8191                        | ✅ kept                   |
| 8192–16383  | `reserved2`  | secure storage, tag `SSKR` — HDCP, DRM, attestation keys | ✅ kept                   |
| 16384–32734 | `uboot`      | `u-boot.itb`                                             | ❌ zeroed, then rewritten |

Sectors 7168–16383 are provisioned in the factory and never recreated. Confirm a board has them —
`N` is the device with `boot0`/`boot1` companions:

```sh
sudo dd if=/dev/mmcblkN bs=1 skip=$((7168*512)) count=4 | tr -d '\0'   # DVKR
sudo dd if=/dev/mmcblkN bs=1 skip=$((8192*512)) count=4 | tr -d '\0'   # SSKR
```

## What the fix does

Merged upstream as `armbian/configng` PR 981, `install: keep the Rockchip reserved window`. In
`apply_partitions()` it probes both tags and narrows the wipe only when one is found:

```sh
keep_window="no"
[[ "$(dd if="$device" bs=1 skip=$(( 7168 * 512 )) count=4 | tr -d '\0')" == "DVKR" ]] && keep_window="yes"
[[ "$(dd if="$device" bs=1 skip=$(( 8192 * 512 )) count=4 | tr -d '\0')" == "SSKR" ]] && keep_window="yes"

if [[ "$keep_window" == "yes" ]]; then
	dd if=/dev/zero of="$device" bs=512 count=7168 conv=notrunc              # 0–7167
	dd if=/dev/zero of="$device" bs=512 seek=16384 count=4096 conv=notrunc   # 16384–20479
else
	dd if=/dev/zero of="$device" bs=1M count=10 conv=notrunc                 # 0–20479, as before
fi
```

It saves `DVKR` and `SSKR` **and nothing else**:

- A board with neither tag is cleared exactly as before — the narrowing is opt-in on evidence.
- The idbloader and `u-boot.itb` are still zeroed, then written back: reconstructed, not preserved.
- Anything else in 0–7167 or 16384–20479 is gone with no way back. Hence the mandatory backup.

## What it was before

❌ **Verified 2026-08-14** against armbian-config `26.8.0-trunk.426.0813`: the shipped
`install_apply_partitions()`, run on a loop device carrying both tags, returned 0, created the
partition, and left sectors 7168 and 8192 zeroed. Its `dd if=/dev/zero bs=1M count=10` cleared
0–20479 unconditionally.

Boxes that survived ran different code. The old standalone TUI `/usr/bin/armbian-install` had an
eMMC-to-eMMC path that never reached that `dd`: menu option 2 calls `format_emmc()`, whose only
destructive write is the MBR partition entries (`dd bs=1 seek=446 count=64`, then `parted`). The 10
MiB `dd` lived in `check_partitions()`, behind a `--yesno` and a radiolist shipping "off", reachable
only from the SATA/USB/NVMe options. The rewrite collapsed every path onto
`install_apply_partitions()`, which runs it unconditionally.

Which code runs is per-image, so check which form yours carries — the old standalone TUI, or a shim
that execs `armbian-config --api module_partitioner` — and diff against the backup afterwards.

## Nothing else guards the window

Checked, because it is the obvious explanation and it is wrong:

- Writing a pattern to sector 7700 on a live `/dev/mmcblkN` sticks, and reads back with
  `iflag=direct`. Both tags can be zeroed and restored the same way.
- There is no block-layer filter and no eMMC write-protect group.
- `sdmmc_vendor_storage` hardcodes `EMMC_VENDOR_PART_START (1024 * 7)` and `EMMC_VENDOR_PART_NUM 4`
  and reaches them through `rk_emmc_transfer()` as a reader and writer, not as a guard. `7168`
  appears nowhere in `drivers/mmc/`.

**After a wipe there is no store at all.** Our U-Boot is mainline and carries no vendor-storage
driver, so nothing recreates `DVKR` — it cannot write one back, and `rk35xx-vendor-storage` simply
finds no tag until the window is restored from the dump. (Rockchip's _vendor_ U-Boot does recreate
it, with an address of its own invention; that behaviour is not in these images.) A snapshot service
keyed on the tag is therefore no substitute for the backup: with the tag gone it has nothing to key
on.

## Verify after any migration

```sh
sudo dd if=/dev/mmcblkN bs=512 count=32768 | cmp -l - <(dd if=backup/<board>/emmc-full.img bs=512 count=32768)
```

**Sectors 7168–16383 must be byte-identical.** Differences at the GPT (0–5), the idbloader and the
`u-boot.itb` region are rewritten by design. Image the whole source medium first regardless.

## Traps when testing this

- A loop-device test showing the tags intact means nothing **unless the function actually ran**.
  Print its return code and confirm it created a partition — a quoting error makes a no-op pass.
- The overlay's `platform_install.sh` override writes only the loader pair, after any wipe. Not
  protection.
