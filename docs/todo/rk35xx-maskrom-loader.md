# Maskrom and Loader — what is still open

Family-wide. `docs/maskrom.md` holds what is established and the procedures; this is only the open
list. It matters because a box with no card slot has no SD rescue, so maskrom is the only way back.

1. ❓ **What ends a read session?** Capacity depends on how recently the box was worked: 12.58 GB
   from idle, **0.59 GB** minutes after that run's stall, 12.22 GB on an earlier idle day. So
   something accumulates and recovers when the box is left alone. Heat is the obvious candidate, and
   a brownout fits as well — the box is bus-powered through the port it is read over. Not the loader
   (both correctly packed `LDR `) and not the media (every sector re-read cleanly later).
   - **Untried: a powered hub**, which separates heat from power.
   - **Untried: a measured cool-down.** Every recovery so far was a replug, which is a power-cycle
     _and_ a cool-down, so neither has been isolated. Nobody has shown that waiting alone restores
     capacity, or how long it takes.
   - ❌ **`rd 2` and `rd 4` cannot rescue a wedged session** (measured 2026-09-12): every `rd`
     subcode is served by `usbplug`, not the BootROM, so they need the very thing that is wedged. A
     replug remains the only way out.
2. ~~**Does a long `wl` die the same way?**~~ **Answered — yes.** A full-clock board writes 15.76 GB
   in one pass at 14-18 MB/s without degrading; a board whose reads stall needs its writes chunked
   too. That is the case that matters: a read stall costs a chunk, a write stall leaves the box
   unbootable until it finishes.

3. ~~**A board on the shared mainline FIT has no button route.**~~ **Answered — and removed.** The
   button is an `adc-keys` entry read by U-Boot and the mainline FIT had no ADC. Every board now
   ships its own FIT with the ADC on and the shared one is deleted, so the case cannot recur. ✅ The
   R69 reached `Maskrom` on the button and passed `db`/`rfi`/`rl`. Per-board ports: ✅ 3518D USB-C,
   bus-powered from the host; ✅ R69 the USB 3 port.

4. ~~**Is the R69's `Maskrom` usable?**~~ **Answered ✅ 2026-09-12** — `db`, `rfi` and `rl` all
   work; a read of sector 64 matched `firmware/r69/factory_idbloader.bin` byte for byte. `wl` is
   proven too: a 4 MiB pattern written to the empty region at LBA 24576, read back byte-exact, then
   the original restored and re-verified.
5. ~~**A software route into maskrom.**~~ **Done ✅ 2026-09-12** — every board's tree now declares
   `mode-maskrom = <0xef08a53c>` in its `syscon-reboot-mode` node, so `sudo reboot maskrom` lands in
   `Maskrom` in ~5 s over SSH. Verified on the H96 Max through `db`, `rfi` and a checked `rl`.

6. ❓ **The 3518D's eMMC CLK test points are unidentified.** That is the only route left for a box
   too broken to reach `Loader`.

## The `uboot` partition is a redundant pair, but not a safety net

4 MiB, two byte-identical 2 MiB halves — a FIT at partition offset 0 and the same FIT again at 2
MiB, disk LBA 16384 and LBA 20480. Real content ends at ~1.47 MB, so each slot is ~25% used.

❌ **Nothing boots the second slot.** SPL does not try it when the first fails its hash; do not plan
an experiment around it. Our own writes put the same FIT in both, so neither backs up the other —
the eMMC backup is what a bootloader experiment falls back to, and `ctrl+b` at the vendor SPL is the
rescue when U-Boot does not reach a prompt.
