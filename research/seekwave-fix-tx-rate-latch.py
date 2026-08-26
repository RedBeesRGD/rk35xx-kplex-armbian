#!/usr/bin/env python3
"""
Seekwave SWT6621S Wi-Fi firmware — fix the TX rate latch at 6 Mbit/s.

SYMPTOM

    Uplink collapses to 6.0 Mbit/s and does not recover, while downlink stays at
    HE-MCS 10/11. Only re-association clears it. Nothing is wrong with the link:
    at the pinned rate the success rate is 92-99% and the failure counter is zero.

    The state is per-TID, not per-station. BE/BK sit at 6 Mbit/s while VI/VO run
    HE-MCS 9-11 on the same association, in the same second -- 58.4 Mbit/s on VI
    against 3.53 on BE with only the DSCP marking changed. So it is not RF, TX
    power, antenna or calibration.

CAUSE -- RETRACTED, DO NOT SHIP THIS PATCH

    The attribution below is WRONG. Peeking ctx[0x1bd] during a latch confirmed
    by real throughput (78.3 -> 5.17 Mbit/s, psr 100 so the readout was live)
    reads 0: the flag is CLEAR while the rate is pinned. It is not the mechanism.

    The A/B spread that seemed to support it -- stock 9/16 latched, flag variants
    20-33% -- was stimulus drift. The reproduction varies enough between windows
    to generate that range on its own, which is why no variant ever eliminated
    the latch and why "fixes" kept regressing on the next batch of reps.

    Retained below as a description of what the flag does, and as a record of how
    a plausible mechanism survived twelve hours of underpowered A/B before one
    ten-minute direct measurement killed it.

SUPERSEDED CAUSE

    A "panic" fallback misfires. It is not a rate-ladder defect at all.

    FUN_0012c338 clears ctx[0x1bd] on entry, then re-arms it when no rate scored
    above zero AND fewer than four rates cleared the minimum-attempts gate:

        0012c412  uxtb.w   r0,r8        ; r0 = rates that had statistics
        0012c418  cmp      r0,#3
        0012c41a  itt      ls
        0012c41c  movls    r0,#1
        0012c41e  strbls.w r0,[r6,#0x1bd]

    The chain builder is the only consumer, and it forces the TX chain's fallback
    entry from 24 Mbit/s down to 6 Mbit/s whenever the flag is set:

        else if (rate_ratio < 0x23 || ctx[0x1bd] != 0) slot = 0x30;  // 6 Mbit/s
        else                                          slot = 0x34;  // 24 Mbit/s

    Host CPU starvation stalls TX-completion processing, so the per-rate
    statistics go missing while the radio stays healthy. The firmware cannot tell
    "I measured failures" from "I have no measurements", treats the empty table as
    a dead link, and pushes traffic onto 6 Mbit/s. The statistics then accumulate
    at 6 Mbit/s and the selector legitimately converges there -- which is why the
    pinned rate reports excellent success. The ladder is faithfully tracking a
    situation the flag manufactured.

    That closed loop explains every earlier dead end: patches to probe
    scheduling, probe backoff, the attempt gate and ladder composition all repair
    the climbing machinery, while the rate is being overridden downstream of it.

FIX

    One word. Arm the fallback only when at least one rate actually produced data
    and still scored zero -- real evidence of failure, rather than absence of
    evidence:

        0012c418  cmp r0,#3  / itt ls  ->  cmp r0,#0 / itt ne

    File offset 0x2c418: 03 28 9c bf -> 00 28 1c bf.

    A genuinely dead link still triggers the fallback (some rate has attempts and
    0% success). An empty statistics table no longer does.

    ctx[0x1bd] has exactly three references in the image -- one unconditional
    clear, this one set, one read in the chain builder -- so this is the only
    site that can arm it.

STATUS -- PARTIAL, NOT CONFIRMED

    Interleaved against a stock control in the same window:

        stock                                       6/9 latched
        flag never armed (movls r0,#1 -> #0)        0/3 latched
        this patch (evidence gate)                  1/5 latched
        cmp r0,#0 / itt ls (wrong direction)        2/2 latched

    The evidence gate reduces the latch rate but does not eliminate it. Under
    starvation the firmware sometimes DOES record attempts with zero successes --
    lost completions are counted as failures -- and in that state the statistics
    table is indistinguishable from a failing link. No gate reading only the
    statistics can separate host starvation from RF failure.

    Separating them needs RF-side evidence, which the firmware already maintains:
    ctx[0x1a6], the averaged per-completion metric updated in FUN_0012d710. A
    correct gate would suppress the fallback while that metric is healthy. Not
    yet implemented.

REJECTED ALTERNATIVES

    cmp r0,#0 / itt ls ("arm only when no rate has data") latched 2/2. That is
    the wrong direction: it narrows the gate onto precisely the starvation case.
    Its failure is also the measurement proving bVar8 == 0 during many latches --
    no rate has any statistics at all.

    Deleting the flag outright (movls r0,#1 -> #0) has no latches so far. Blunt,
    but the flag only selects the retry-chain fallback slot (24 -> 6 Mbit/s), so
    removing it does not disable rate adaptation: a bad link still descends the
    ladder normally. Reps still accumulating.

REPRODUCING IT

    2.4 GHz, stress-ng --cpu 4, Wi-Fi idle during the load, measured after it
    stops. THE BAND IS THE VARIABLE: the identical stimulus does nothing on
    5 GHz even at load 14 with saturated TX, and reproduces on 2.4 GHz in under
    60 s. Signal strength is not the factor -- it reproduced at -23 dBm on
    2.4 GHz while -32 dBm on 5 GHz would not budge.

    Pin the band at runtime, without touching any config file:

        wpa_cli -i wlan0 set_network 0 freq_list 2412 ... 2462

    Stock latches about 4 times in 5. Score every candidate against a stock
    control interleaved in the same window -- a quiet window has invalidated
    several earlier comparisons.

CHECKSUM

    Nothing to rebuild. The image is raw Cortex-M code: offset 0 is the vector
    table, there is no header, trailer or checksum field. The host driver
    computes its own CRC-16 over the buffer it downloads, so it covers the
    patched bytes automatically.

    Not every byte is patchable: 0x2c890 and 0x57ea2 tolerate edits while
    0x14f20 makes the chip fail to boot. Verify the chip still boots after any
    new patch site.

USAGE

    seekwave-fix-tx-rate-latch.py <image> [-o OUT] [--revert] [--check]

    Patches in place unless -o is given. Refuses any file that is not a stock or
    already-patched SWT6621S IRAM image. Re-running is safe.
"""

import argparse
import hashlib
import sys

LOAD_BASE = 0x00100000
SITE_ADDR = 0x0012C418
SITE_OFF = SITE_ADDR - LOAD_BASE
STOCK = 0xBF9C2803
PATCHED = 0xBF1C2800
NAMES = {STOCK: "stock", PATCHED: "patched"}


class NotFirmware(Exception):
    pass


def read_word(image, offset):
    return int.from_bytes(image[offset : offset + 4], "little")


def verify_is_firmware(image):
    """Reject anything that is not an SWT6621S IRAM image, before writing to it."""
    if len(image) < SITE_OFF + 4:
        raise NotFirmware(f"too small: {len(image)} bytes")
    stack_top, reset_vector = read_word(image, 0), read_word(image, 4)
    in_image = lambda a: LOAD_BASE <= a < LOAD_BASE + len(image)
    if not in_image(stack_top):
        raise NotFirmware(f"initial SP {stack_top:#010x} is outside the image")
    if not in_image(reset_vector) or not reset_vector & 1:
        raise NotFirmware(f"reset vector {reset_vector:#010x} is not Thumb code")
    if read_word(image, SITE_OFF) not in NAMES:
        raise NotFirmware(
            f"word at {SITE_ADDR:#010x} is {read_word(image, SITE_OFF):#010x}, "
            "which is neither the stock nor the patched instruction"
        )
    return stack_top, reset_vector


def describe(image):
    return NAMES[read_word(image, SITE_OFF)]


def apply_word(image, word):
    patched = bytearray(image)
    patched[SITE_OFF : SITE_OFF + 4] = word.to_bytes(4, "little")
    return bytes(patched)


def main():
    parser = argparse.ArgumentParser(
        description="Fix the SWT6621S TX rate latch at 6 Mbit/s.",
        epilog="Run with --check to inspect an image without modifying it.",
    )
    parser.add_argument("image", help="SWT6621S IRAM firmware image")
    parser.add_argument("-o", "--output", help="write here instead of in place")
    parser.add_argument("--revert", action="store_true", help="restore the stock instruction")
    parser.add_argument("--check", action="store_true", help="report state and exit")
    args = parser.parse_args()

    try:
        image = open(args.image, "rb").read()
    except OSError as err:
        sys.exit(f"cannot read {args.image}: {err}")

    try:
        stack_top, reset_vector = verify_is_firmware(image)
    except NotFirmware as err:
        sys.exit(f"refusing {args.image}: {err}")

    before = describe(image)
    print(f"{args.image}")
    print(f"  {len(image)} bytes, SP {stack_top:#010x}, reset {reset_vector:#010x}")
    print(f"  {SITE_ADDR:#010x} (offset {SITE_OFF:#07x}) = {read_word(image, SITE_OFF):#010x}  [{before}]")

    if args.check:
        return

    want = STOCK if args.revert else PATCHED
    if read_word(image, SITE_OFF) == want:
        print(f"  already {NAMES[want]}, nothing to do")
        return

    patched = apply_word(image, want)
    destination = args.output or args.image
    try:
        open(destination, "wb").write(patched)
    except OSError as err:
        sys.exit(f"cannot write {destination}: {err}")

    print(f"  -> {want:#010x}  [{NAMES[want]}]")
    print(f"  wrote {destination}, sha256 {hashlib.sha256(patched).hexdigest()}")
    print("  install over every real image file (board-suffixed names are usually")
    print("  symlinks — resolve them first), then reload the driver")


if __name__ == "__main__":
    main()
