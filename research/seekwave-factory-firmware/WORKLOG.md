# Worklog — factory Seekwave chip images

## 2026-09-12 — the swap reason turns out to be one opcode

Raised while chasing BT remote wake: every wake measurement had been taken on the KICKPI K3B chip
code, not the images this hardware shipped with, so the whole investigation might have been running
on firmware Android never used.

Checked. `firmware/common/seekwave-fw/README.md` says so outright, and the shipped DRAM/IRAM differ
from `stock/h96max-3518d/firmware/` while the RF calibration matches. The reason is in
`docs/h96max/worklog.md`: the factory images assert at `Read Local Supported Codec Capabilities`.

So the blocker was never "the factory firmware is bad" — it was one advertised-but-broken opcode.

Wrote `0007` to answer the three codec reads in the driver. Considered and rejected
`HCI_QUIRK_BROKEN_LOCAL_COMMANDS`: it avoids the same commands by skipping the supported-commands
read entirely, which zeroes the bitmap and disables far more than it fixes.

Compiled clean. Swapped the images in, loaded with `skip_codec_reads=1`:

```
[SKWBT_INFO] answering codec read 0x100d locally
hci0: UP RUNNING
```

The factory chip code had been unrunnable under Linux since August and now runs.

**It changes nothing about wake.** Suspend `165.49 → 167.64` = 2.16 s, wake irq 66, `ADV_DIRECT_IND`
in the trace — the same reconnect hunt as the 2.00 s K3B baseline. Owner confirmed independently:
"seems like auto wakes the same".

Also learned: the factory images answer `LE_Get_Vendor_Capabilities` with Unknown HCI Command, where
K3B replies. Fewer vendor extensions, not more.

**Method note.** The swap was performed by unloading `skw_sdio_lite` over ssh — that is the Wi-Fi
transport, so it severed the connection mid-operation and cost a power cycle. Everything afterwards
touched `skwbt` only. A driver swap that takes down the only network path has to run detached with a
self-revert on failure.

Parked as a draft at the owner's call: the board keeps the K3B build, and this folder holds the
patch and the reasoning for whenever the correctness argument is worth the soak.

## 2026-09-13 — parked in the repo, left running on the box

Repo ships K3B; the test box keeps the factory images and `skip_codec_reads=1`. Deliberate: the
patch and the firmware choice are the work product, and the box accumulates soak time on them while
nothing downstream inherits the change. A `rk35xx-update` run would overwrite the box's firmware
back to K3B, so that is the thing to watch for, not the divergence itself.
