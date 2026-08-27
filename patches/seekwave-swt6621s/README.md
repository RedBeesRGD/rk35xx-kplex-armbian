# seekwave-swt6621s — driver patches

Fixes for the H96 Max's Wi-Fi/BT driver, applied to the pinned source by
`firmware/h96max/fetch-seekwave-src.sh` at image build and by `rk35xx-update` on a live box. Applied
in filename order.

| Patch  | PR                                                           | Fixes                                            |
| ------ | ------------------------------------------------------------ | ------------------------------------------------ |
| `0002` | [#1](https://github.com/retro98boy/seekwave-swt6621s/pull/1) | uplink latching at 6 Mbit/s until re-association |
| `0003` | [#2](https://github.com/retro98boy/seekwave-swt6621s/pull/2) | driver chatter filling the kernel error log      |

`0001` from the same investigation is superseded and not carried: it re-arms TX BA on a blind timer,
and against an AP that holds a session for minutes it would renegotiate a healthy link every
interval. It is in `research/seekwave-tx-latch-bug/patches/`.

Both apply to pinned commit `b1b15016`. `./firmware/h96max/fetch-seekwave-src.sh <dir>` fetches and
patches into `<dir>`, which is how to check they still apply after a version bump.
