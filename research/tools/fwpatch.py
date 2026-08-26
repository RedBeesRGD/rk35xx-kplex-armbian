#!/usr/bin/env python3
"""Patch the SWT6621S rate-control probe suppression in an IRAM image.

Sites (aligned 32-bit words, little-endian):

  clamp @0x0012c890 -- the probe backoff accumulator:
      0012c88c  lsl.w  r0,r2,r0   ; r0 = 1<<exp, exp saturates at 6 so <= 64
      0012c890  add    r0,r1      ; += backoff  <-- unclamped, stored to a signed char
      0012c89a  strb.w r0,[r5,#0x1a9]
    nop  -> backoff becomes 1<<exp: bounded at 64 intervals, never negative.
            Measured: does NOT fix the latch (never recovers in 150 s, 2/2).
    zero -> movs r0,#0, so the counter is cleared on every lost probe and the
            backoff can never suppress at all.

  bypass @0x0012c800 -- blunt instruments, for isolating which path pins the rate:
      0012c800  cmp  r0,r1
      0012c802  beq  0x12c79e     ; (A) best == ladder max -> return
      0012c808  cbz  r0,0x12c82e  ; (B) backoff == 0 -> probe
    A  = nop the beq          -> bypass (A), backoff still honoured
    AB = branch to the probe  -> bypass both, probe every interval

  ofdm @0x0012d38c -- the ladder builder deletes every OFDM rate except 6 Mbit/s
    whenever the peer advertises HT/VHT/HE:
      0012d38a  lsls r1,r1,#0x1d   ; caps & 7
      0012d38c  beq  0x12d396      ; not HT/VHT/HE -> keep the rate
      0012d390  bne  0x12d5d0      ; else drop unless code == 0x30
    If HT/VHT/HE admission then fails, one entry survives and the ladder is pinned
    to its own top at 6 Mbit/s.
    keep -> make the beq unconditional, so OFDM rates are never deleted.

  recap @0x0012d688 -- rc_init refreshes the per-STA capability map (ROM call
    func_0x000c8c48) only on the FIRST init; later rebuilds reset the state and
    branch past it, so they re-derive the ladder from a map they never refresh:
      0012d67c  cbz  r0,0x12d68c   ; state == 0 -> ROM populate path
      0012d684  strb r0,[lr,#0x1b4]; else: state = 0
      0012d68a  b    0x12d6b0      ; ...and skip the ROM call
      0012d68c  (ROM populate)
    always -> retarget that branch to 0x12d68c, so a rebuild resets the state AND
    refreshes capabilities. Makes MIB 0x50 a real non-disruptive recovery.

  flagveto @0x0012c41c / flaggate @0x0012c418 -- the "panic" fallback.
    FUN_0012c338 clears ctx[0x1bd] every call, then re-arms it when no rate scored above
    zero AND fewer than four rates had statistics:
      0012c412  uxtb.w r0,r8     ; r0 = count of rates that cleared the attempt gate
      0012c418  cmp    r0,#3
      0012c41a  itt    ls
      0012c41c  movls  r0,#1
      0012c41e  strbls.w r0,[r6,#0x1bd]
    The chain builder then hard-codes 6 Mbit/s on that flag (0012c9d8 movs r1,#0x30),
    overriding the ladder entirely. Under CPU starvation the statistics are missing because
    the host could not process TX completions -- the radio is fine (psr 94, tx_failed 0, RX at
    HE-MCS 10) -- so the fallback misfires and pins a good link at 6 Mbit/s.
    veto     -> movls r0,#0, so the flag is never armed. Blunt: removes the fallback outright.
    zeroonly -> cmp r0,#0, so it arms only when NO rate has any statistics at all, which is
                genuinely degenerate. Keeps the safety net, drops the misfire. Preferred fix.

  bwclamp @0x0012c2ec -- FUN_0012c27a steps the channel bandwidth down (80/40/20 via ROM
    func_0x000c8888) and, on the way down, pins the rate index to the threshold ctx[0xa6]:
      0012c2a8  cmp  r6,r4      ; r6 = ctx[0xa6]+1, r4 = requested rate index
      0012c2aa  bhs  0x12c2c4   ; threshold+1 >= requested -> downgrade path
      0012c2ee  mov  r4,r7      ; clamp requested index to ctx[0xa6]
    Restore needs ctx[0xa6]+1 < requested, which the clamp itself prevents -- a one-way
    ratchet in the bandwidth path rather than the rate ladder. Consistent with a pin that
    reports psr 92-99 and tx_failed 0: at 20 MHz on a low rate nothing actually fails.
    noclamp -> nop the mov, keeping bandwidth stepping but letting the index rise again.
    UNTESTED: needs a live reproduction, which has not been available since the box moved
    to -32 dBm.
"""
import sys, hashlib

BASE = 0x00100000
SITES = {
    "clamp":  (0x0012c890, {"orig": 0x29ff4408, "nop": 0x29ffbf00, "zero": 0x29ff2000}),
    "bypass": (0x0012c800, {"orig": 0xd0cc4288, "A": 0xbf004288, "AB": 0xe0144288}),
    "ofdm":   (0x0012d38c, {"orig": 0x2830d003, "keep": 0x2830e003}),
    "recap":  (0x0012d688, {"orig": 0xe0114677, "always": 0xe7ff4677}),
    "bwclamp": (0x0012c2ec, {"orig": 0x463cfacd, "noclamp": 0xbf00facd}),
    "flagveto": (0x0012c41c, {"orig": 0xf8862001, "veto": 0xf8862000}),
    "flaggate": (0x0012c418, {"orig": 0xbf9c2803, "zeroonly": 0xbf9c2800,
                              "evidence": 0xbf1c2800}),
}

def main(a):
    if len(a) != 5 or a[2] not in SITES or a[3] not in SITES[a[2]][1]:
        print(__doc__)
        print("usage: fwpatch.py <image> <site> <variant> <out>")
        for s, (addr, v) in SITES.items():
            print(f"  {s:7s} @{addr:#010x}  variants: {', '.join(v)}")
        return 2
    src, site, variant, dst = a[1], a[2], a[3], a[4]
    addr, variants = SITES[site]
    d = bytearray(open(src, "rb").read())
    off = addr - BASE
    cur = int.from_bytes(d[off:off+4], "little")
    if cur not in variants.values():
        print(f"REFUSING: word at {addr:#x} is {cur:#010x}, not a known {site} variant")
        return 1
    d[off:off+4] = variants[variant].to_bytes(4, "little")
    open(dst, "wb").write(d)
    print(f"{src} -> {dst}")
    print(f"  {site} @{addr:#010x}: {cur:#010x} -> {variants[variant]:#010x}  ({variant})")
    print(f"  size {len(d)}  sha256 {hashlib.sha256(d).hexdigest()[:16]}")
    return 0

sys.exit(main(sys.argv))
