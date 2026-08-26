# SWT6621S firmware — memory map and structures

## Images and load addresses

| Image | Base | Size | Contents |
| --- | --- | --- | --- |
| `SWT6621S_IRAM_SDIO.bin` | `0x00100000` | 360128 B | Wi-Fi/BT stack. Verified: vector table at 0, SP `0x00107fd8`, reset `0x00104725` (Thumb bit set), disassembles as valid Cortex-M startup |
| `SWT6621S_DRAM_SDIO.bin` | `0x20200000` | 193468 B | data + BT/RF-calibration code. Verified: rate table lands exactly at its symbol address `0x20217CE0` (file offset `0x17CE0`) |
| ROM | `0x00044000`-`0x000dc656` | ~610 KB | **not available.** 797 distinct entry points, 2176 call sites from IRAM |

Architecture: ARM Cortex-M, Thumb. Firmware is **not** encrypted (IRAM entropy 6.71/8, DRAM 4.03/8).
Build stamp `20260307-01:02:24`. Stack is RivieraWaves/CEVA derived (`rwip.c`, `sch_arb.c`,
`machw_*.c`, `rate_control.c`).

Note: deriving the DRAM base by pointer-scoring gives `0x20000000`, which is **wrong** — a local
maximum. `0x20200000` is correct, anchored on the known rate-table address.

## Global rate table — `0x20217CE0`, 57 entries x 6 bytes

`{u8 idx, u8 hw_code, u8 mode, u8 nss, u16 mbps}`, ascending by rate. Decoded in `rate-table.txt`.

mode 0 = CCK/DSSS (codes `0x10`-`0x13`, `0x20`-`0x23`) · mode 1 = legacy OFDM (`0x30`-`0x37` =
6,9,12,18,24,36,48,54) · 2 = HT · 3 = VHT · 4 = HE · 5-7 = HE variants (ER/DCM).

**Entry 9 = code `0x30`, OFDM, 6 Mbit/s — the latched rate.**

## Per-station rate-control context

`ctx = *(u32 *)(0x202233B4 + sta_idx * 4)`, size `0x1e0`.

| Offset | Meaning |
| --- | --- |
| `0x08 / 0x0c / 0x14 / 0x16` | legacy-rate bitmap / HT MCS / VHT map / **HE per-NSS map** (written by ROM; 3 = unsupported) |
| `0x18`-`0xa3` | ladder: 28 entries x 5 bytes, `[0]` = index into global table, ascending |
| **`0xa4`** | **highest valid ladder index** — 0 means a one-entry ladder (the latch) |
| `0xa5 / 0xa6` | last NSS-1 index / first HT-VHT-HE index (init `0x1c` = invalid) |
| **`0xaa`** | **current rate index** — what the host reports |
| `0xab`-`0xb2`, `0xb3`-`0xba` | the two 8-slot retry chains |
| `0xbc`-`0x19b` | per-rate stats, 28 x 8 B: `+0` u32 attempts, `+4` count, `+5` EWMA-converged, `+6` s8 EWMA success % |
| `0x1a4 / 0x1a6 / 0x1a7` | success % / avg RSSI ch0 / ch1 |
| **`0x1a8` / `0x1a9`** | **probe backoff exponent (cap 6) / suppression countdown (signed char)** |
| **`0x1b4` / `0x1b5`** | **state: 0 init, 1 normal, 2 probe-active, 3 probe-idle / probe sub-counter** |
| `0x1b6 / 0x1b7` | max NSS / probe rate index |
| `0x1bc / 0x1bd / 0x1be` | force-rebuild / too-few-samples / NSS reduction |

## Config struct — `*DAT_001081E0` (installed by ROM, reads 0 statically)

`+0x00` mode (0 auto, 1 fixed index, 5 fixed code) · `+0x0b` basic-rate code · `+0x11` tick divisor
· `+0x24` force-rebuild · **`+0x25` min attempts to be a candidate** · `+0x26/+0x27` retry counts ·
**`+0x29` probe step** · `+0x2a` down-step · `+0x2d` build counter.

Host-writable: **cmd 0x50** sets `[0x2c]` and `[0x24]=1` (triggers rebuild, no deauth);
**cmd 0x51** writes `[0x2a], [0x29], [0x2b], [0x26], [0x27]`. Handler `FUN_00122724`, decomp.c 25630.

## rate_control.c function map — `0x0012c27a`-`0x0012d710`

| Address | decomp.c | Role |
| --- | --- | --- |
| `FUN_0012c27a` | 33603 | NSS reduction / bandwidth-fallback clamp |
| **`FUN_0012c338`** | 33642 | **selection: argmax(EWMA% x Mbps); down-step fallback; wipes all stats (33707)** |
| **`FUN_0012c478`** | 33853 | **retry-chain builder; injects probe rate `cur + config[0x29]` (33890)** |
| `FUN_0012c672`-`0012c714` | 33996-34056 | getters (RSSI, success %, ctx, current rate entry) |
| **`FUN_0012c740`** | 34068 | **state machine; only writer of `ctx[0xaa]`; the latch is at 34120** |
| `FUN_0012c8c8` | 34192 | rate-code supported test |
| `FUN_0012c900` | 34210 | chain -> HW rate codes, BW, AMPDU cap |
| **`FUN_0012cc50`** | 34363 | **periodic per-VIF tick; rebuild if flagged; calls collector every `config[0x11]`** |
| `FUN_0012cf84 / 0012d012` | 34533/34564 | fixed-rate modes |
| `FUN_0012d124` | 34582 | `memset(ctx, 0, 0x1e0)` — STA delete |
| `FUN_0012d15a` | 34598 | push chain to HW (ROM `func_0x000c8f92`) |
| **`FUN_0012d284`** | 34674 | **`rc_init` — ladder builder. Deletes OFDM>6M at 34763-65; HE gate at 34816; sets `ctx[0xa4]` at 34879** |
| **`FUN_0012d710`** | 34899 | **stats collector -> EWMA -> calls the state machine. Frozen if ROM reports no TX (34940)** |

Callers of `rc_init`: `FUN_001162da` 14814 (assoc/reassoc response, status 0), `FUN_0011c186` 20441
(AP-side assoc req), `FUN_00128e48` 31286, and the periodic tick at 34402/34463/34473.

Host reporting path: `FUN_0011df32` (21695) returns
`rate_table[ladder[ctx[0xaa]]].mbps * 10` in 100 kbit/s units.

Firmware trace: module id **0x30**, events `0x5485` (decision) and `0x548b` (per-rate stats).
