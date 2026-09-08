# Seekwave SWT6621S firmware

Shared by every board carrying this radio. Installed to `/lib/firmware/` by each board's
`payload.list`, which also picks the NV variant.

| File                                  | Origin                                                           |
| ------------------------------------- | ---------------------------------------------------------------- |
| `SWT6621S_DRAM_SDIO.bin`              | `armbian/firmware`, `seekwave/SWT6621S_DRAM_SDIO.kickpi,k3b.bin` |
| `SWT6621S_IRAM_SDIO.bin`              | `armbian/firmware`, `seekwave/SWT6621S_IRAM_SDIO.kickpi,k3b.bin` |
| `SWT6621S_NV_SDIO_STANDALONE_FDD.bin` | factory NV — `BT_ANTENNA_TYPE` stand-alone, `COEX_TYPE` FDD      |
| `SWT6621S_NV_SDIO_SHARED_TDD.bin`     | factory NV — `BT_ANTENNA_TYPE` shared, `COEX_TYPE` TDD           |
| `SWT6621S_SEEKWAVE_R00001.bin`        | RF calibration, read off a box's vendor partition                |
| `sv6160lite.nvbin`                    | driver repo `retro98boy/seekwave-swt6621s` — BT NV               |

Chip code is the KICKPI K3B build, not either factory image; `docs/h96max/worklog.md` records the
Bluetooth failure that forced the swap. Chip code may be upgraded; NV and RF calibration may not.

The two NV variants differ in two bytes — `0x20` `BSP_CFG0` bit0 and `0x24` `BT[0]` — decoded by the
vendor's `SWT6621S_NV_SDIO.ini` in `stock/h96max/firmware/`. That is configuration, not per-unit
identity, which is what makes them shareable. Both install as `/lib/firmware/SWT6621S_NV_SDIO.bin`,
so these two filenames alone do not mirror their installed name.

For a new board, `cmp` its factory NV against both: a match is one `payload.list` line, a difference
gets a new file named for what it sets.
