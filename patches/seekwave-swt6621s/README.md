# seekwave-swt6621s — driver patches

Fixes for the Wi-Fi/BT driver shared by the H96 Max and H96 Max 3518D, applied to the pinned source
by `firmware/common/fetch-seekwave-src.sh` at image build and by `rk35xx-update` on a live box.
Applied in filename order.

- `0002` — uplink latching at 6 Mbit/s until re-association.
  [PR #1](https://github.com/retro98boy/seekwave-swt6621s/pull/1)
- `0003` — driver chatter filling the kernel error log.
  [PR #2](https://github.com/retro98boy/seekwave-swt6621s/pull/2)
- `0005` — the factory chip images advertise the HCI codec reads and then assert on them
  (`BSPASSERT:hci_tl.c-386`), ending controller init. The driver answers `0x100b`, `0x100d` and
  `0x100e` locally with Unknown HCI Command so they never reach the chip. Off by default; both
  boards enable it with `skwbt.skip_codec_reads=1` from `firmware/common/skwbt-options.conf`, since
  both run the factory chip code. Not submitted upstream.

Every patch here applies to pinned commit `b1b15016`.
`./firmware/common/fetch-seekwave-src.sh <dir>` fetches and patches into `<dir>`, which is how to
check they still apply after a version bump.
