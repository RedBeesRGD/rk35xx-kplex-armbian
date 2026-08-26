# Reproducing the analysis

Firmware blobs live in `../../../firmware/h96max/seekwave-fw/`
(also `/lib/firmware/` on a running box).

## 1. Decompile

Needs Ghidra (open source) and a JDK. Ghidra **rejects any path containing a dot-prefixed
component**, so do not work under `~/.cache`, `~/.claude` etc.

```sh
brew install openjdk
curl -sL -o ghidra.zip "$(curl -s https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
  | grep -o 'https://[^"]*_PUBLIC_[0-9]*\.zip' | head -1)"
unzip -q ghidra.zip -d /tmp/fwre

cp DumpDecomp.java /tmp/fwre/ghidra_*/Ghidra/Features/Base/ghidra_scripts/

/tmp/fwre/ghidra_*/support/analyzeHeadless /tmp/fwre/proj fw \
  -import SWT6621S_IRAM_SDIO.bin \
  -processor ARM:LE:32:Cortex \
  -loader BinaryLoader -loader-baseAddr 0x00100000 \
  -postScript DumpDecomp.java
```

Yields 1754 functions. Adjust the output path inside `DumpDecomp.java`.

For DRAM use `-loader-baseAddr 0x20200000` (**not** `0x20000000` — pointer-scoring suggests that
and is wrong; the correct base is anchored on the rate table at `0x20217CE0`).

Python scripting via PyGhidra fails on Python 3.14 (RecursionError in JPype); the Java script above
is the reliable route, and it must live in Ghidra's own `ghidra_scripts` directory or OSGi will
refuse to load it.

## 2. Extract the rate table

```sh
python3 - <<'PY'
import struct
d = open("SWT6621S_DRAM_SDIO.bin","rb").read()
for i in range(57):
    idx, code, mode, nss, mbps = struct.unpack_from("<BBBBH", d, 0x17CE0 + i*6)
    print(f"{i:3} idx={idx:3} code=0x{code:02x} mode={mode} nss={nss} {mbps} Mbps")
PY
```

## 3. Anchors, if starting over

- `strings` finds `rate_control.c` — but the copy at file offset `0x406e2` is **not** the one the
  code references. Ghidra resolves the referenced copy and names it `s_rate_control_c_001406e2`;
  grep the decompilation for that symbol instead of searching for pointers by hand.
- The assert macro is `assert(msg, filename, line)`, which is what makes source filenames and line
  numbers recoverable throughout.
- The per-station context array `0x202233B4` is referenced only within `rate_control.c`, so grepping
  it delimits the module exactly.

## 4. On-box scripts

Copy to `/tmp` on the box and run under `sudo`. All of them force traffic with
`iperf3 --bind-dev wlan0` and quote `/sys/class/net/*/statistics/tx_bytes` deltas — **`-B <ip>`
silently uses ethernet on this box.** Peer defaults to `192.168.1.211`.

| script | what it does |
|---|---|
| `idlestress-repro.sh` | **the reproducer** — CPU load with Wi-Fi idle, then measure after the load stops |
| `abpin.sh` | A/B stock vs patched against that stimulus, band pinned to 2.4 GHz |
| `starve-sweep.sh` | which stressor actually collapses TX — cpu/vm/io/hdd/sock/switch |
| `stress-repro.sh` | CPU load **with** traffic running (negative result: does not latch) |
| `mmcio-repro.sh` | MMC/SDIO IO load (negative result: does not latch) |
| `wlan-measure.sh [secs]` | one forced-`wlan0` throughput sample with counters and link state |
| `repro-latch.sh [n]` | reassociate → probe → classify; stops on the first true latch |
| `repro-reload.sh [n]` | same, but cold-starts the firmware each trial (~20 s), load arm alternating |
| `repro-v3.sh [n]` | `repro-latch.sh` holding a BE flow across the association |
| `idle-repro.sh <secs…>` | hold the link idle/trickle after associating, *then* load — the low-offered-load trigger |
| `triage-latch.sh` | on a live latch: AC sweep, UDP, small-MSS, rate-floor sweep with `psr` readback |
| `latchdiag.sh` | on a live latch: per-TID check plus a 12-minute soak, association events counted |
| `trigger-latch.sh` | induce TX failures via a raised rate floor, then release |
| `autotest3.sh` | chain: reproduce by cold start, then run `latchdiag.sh` while still latched |
| `fw-install.sh <img\|restore>` | install an IRAM image into both firmware dirs and cold-start |

Host tools:

| tool | |
|---|---|
| `fwpatch.py <img> <site> <variant> <out>` | sites: `recap` (root cause), `ofdm`, `clamp`, `bypass` |
| `disasm.py <start> <end>` | capstone Thumb disassembly of `iram.bin` at load base `0x00100000` |
| `skw_ratectl.py` | MIB 0x50 (`rebuild`) and 0x51 (`tune`) via private WEXT ioctl |
| `skwmem.py rd\|wr` | `rdaddr`/`addrval`. **`wr` costs one re-association every time** — see README |

**Detector caveat.** Classify a latch on **legacy mode AND** low throughput. Throughput alone
false-positives: trials at `mcs: 11` measure 8–33 Mbps while settling right after association.

**Never `pkill -f <script>` from an ssh one-liner** — the pattern matches your own command line and
kills the session. Use a regex that cannot match itself, e.g. `pkill -f "repro.latch[.]sh"`, and
never in the same command as the relaunch.
