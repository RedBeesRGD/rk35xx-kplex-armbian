# seekwave-swt6621s — driver patches

Fixes for the Wi-Fi/BT driver shared by the H96 Max and H96 Max 3518D, applied to the pinned source
by `firmware/common/fetch-seekwave-src.sh` at image build and by `rk35xx-update` on a live box.
Applied in filename order.

- `0002` — uplink latching at 6 Mbit/s until re-association.
  [PR #1](https://github.com/retro98boy/seekwave-swt6621s/pull/1)
- `0003` — driver chatter filling the kernel error log.
  [PR #2](https://github.com/retro98boy/seekwave-swt6621s/pull/2)

Every patch here applies to pinned commit `b1b15016`.
`./firmware/common/fetch-seekwave-src.sh <dir>` fetches and patches into `<dir>`, which is how to
check they still apply after a version bump.
