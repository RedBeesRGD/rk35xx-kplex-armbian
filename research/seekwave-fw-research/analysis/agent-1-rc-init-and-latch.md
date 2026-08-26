# Agent report — FUN_0012d284 (`rc_init`) and the hard latch

Verbatim subagent output. Scope: analyse `FUN_0012d284`, identify rate state, determine whether an
up-shift path exists.

---

## 1. What `FUN_0012d284` actually is

**It is not the rate-adaptation loop. It is `rc_init` — the per-STA rate-ladder *builder*.** (decomp.c lines 34674-34896, `FUN_0012d284(vif_idx, sta_idx)`)

Step by step:

1. `iVar12 = *(int *)(param_2*4 + 0x202233b4)` (L34697) — fetch the per-STA rate-control context (`rc_sta`). `func_0x000d3864()` (ROM) returns the `sta_info`; bail if 0.
2. `FUN_0013dfae(iVar10+0x18, 0x8c)` (L34703) — zero the 28-entry × 5-byte rate list at `+0x18..+0xa3`. Then `+0xa6 = +0xa5 = 0x1c` (L34704-05, `0x1c = 28 =` "invalid"), `+0x1b5 = 0`, `+0x1a8 = 0` (a 16-bit store, so **`+0x1a9` is cleared too**).
3. L34708-34717: `uVar5 = min(ROM_max_nss(vif), sta[0x2c]>>4)` → stored at `+0x1b6`.
4. L34718-34727: reverse-scan the 57-entry global rate table for the entry whose *rate code* equals `config[0x0b]` (the configured lowest/basic rate); take its Mbps value into `uVar11` — the floor for the ladder.
5. L34734-34875: walk the global rate table **ascending** (`iVar10 = 0 … 0x150`, stride 6). An entry is admitted only if NSS ≤ max, not filtered by `config[2]`, and `rate ≥ uVar11` (L34735-37), then a per-format gate:
   - **type 0 (DSSS/CCK)** L34739-57 — needs the bit in the STA supported-rate bitmap `rc_sta+8`; drops short-preamble codes `0x1x`; asserts `rate_control.c:1643` if the code→bit map fails.
   - **type 1 (OFDM)** L34761-73 — needs the bitmap bit; asserts `rate_control.c:1672`. **L34763-34765: if `sta[0xc]&7 != 0` (STA has *any* HT/VHT/HE capability) then only code `'0'` (0x30 = 6 Mbit/s) survives; 9/12/18/24/36/48/54 are all dropped.**
   - **type 2 (HT)** L34806 — requires `sta[0xc]&7 == 1` plus the HT MCS bitmap `rc_sta+0xc`.
   - **type 3 (VHT)** L34774-34804 — requires `(sta[0xc]&6) == 2` plus the 2-bit-per-NSS map at `rc_sta+0x14`.
   - **types 4-7 (HE)** L34811-34841 — requires `sta[0xc]` bit 2, plus the 2-bit-per-NSS HE map at `rc_sta+0x16` (value 3 ⇒ unsupported ⇒ entry dropped), plus `sta[0xd]` bit 2 for MCS 10/11, plus `FUN_001235f2`/`FUN_0012359a` (DCM/ER gating).
   - `+0xa6` is latched to the index of the **first** HT/VHT/HE rate (L34801-03, L34826-28).
6. L34843-34868: append the surviving entry: `list[n].tbl_idx = bVar13`, `list[n].code = cVar9`, dedup marker 1/2/3; hard cap of 28 entries.
7. L34876-34880: `rc_sta[0xa4] = n-1` — the highest valid ladder index. **If zero entries were produced, `+0xa4` is left stale** (it sits just outside the memset range).
8. L34881-34888: if state `+0x1b4` was 0 → bump global `config[0x2d]`, call ROM `func_0x000c8c48`, and force `*config = 0` (auto mode); otherwise **reset state to 0**.
9. L34889-34893: `FUN_0012c740(sta)` (the state machine → picks a start index), then ROM HW programming. Tail is `halt_baddata()` (a tail call Ghidra could not decode).

**Ladder ordering is confirmed: index 0 = lowest rate, `+0xa4` = highest.**

I recovered the global rate table from `fw/SWT6621S_DRAM_SDIO.bin` (DRAM load base **0x20200000**, table at file offset 0x17ce0 = 0x20217CE0). Layout per 6-byte entry: `[0]`=index, `[1]`=rate code, `[2]`=format class, `[3]`=NSS, `[4:6]`=**rate in Mbit/s**. 57 entries, ascending 1…143 Mbit/s: CCK `0x20-0x23`/`0x10-0x12`, OFDM `0x30-0x37` (6…54), HT `0x40-0x47`, VHT `0x80-0x89`, HE `0xC0-0xCB` (9…143), HE-ER/DCM `0xCC-0xCF`/`0xDC-0xDF`/`0xEC-0xEF`.

`FUN_0011df32` (L21695) reports the TX rate to the host as `rate_table[list[rc_sta+0xaa]].rate * 10` (100 kbit/s units). **So the observed "6.0 Mbit/s OFDM" is exactly rate code 0x30, and for a 5 GHz HE association it is ladder index 0** — because rule L34763-65 deletes every other OFDM rate, and HT/VHT are excluded by mode.

## 2. Rate-state variables

Global rate table `0x20217CE0` (`DAT_20217ce1/ce2/ce3/ce4` = code/type/nss/rate) — read-only, never written by any function in the image.
`0x202233B4` — array of `rc_sta*` indexed by STA. `DAT_001081E4` — array of `sta_info*`. `DAT_00108320` — array of VIF pointers (used only at L34741 to test VIF type; **not** rate state).
`DAT_001081E0` — pointer to the rate-control **config struct**.

`rc_sta` fields the module uses:

| off | meaning |
|---|---|
| `+0x08/+0x0c/+0x14/+0x16` | legacy-rate bitmap / HT MCS bitmap / VHT map / HE map (written by **ROM**) |
| `+0x18..0xa3` | 28 × 5-byte ladder entries |
| `+0xa4` | highest ladder index |
| `+0xa5 / +0xa6` | last NSS-1 index / first HT-VHT-HE index (init 0x1c) |
| **`+0xaa`** | **current rate index** |
| `+0xab..0xb2`, `+0xb3..0xba` | the two 8-step retry chains |
| `+0xbc..0x19b` | 28 × 8-byte per-rate stats: `+0` u32 attempts, `+4` count, `+5` EWMA-converged flag, `+6` s8 EWMA success % |
| `+0x1a4/+0x1a6/+0x1a7` | success %, avg RSSI ch0/ch1 |
| **`+0x1a8 / +0x1a9`** | **probe backoff exponent / probe-suppression countdown** |
| **`+0x1b4 / +0x1b5`** | **state (0-3) / probe sub-counter** |
| `+0x1b7` | probe rate index |
| `+0x1bc / +0x1bd / +0x1be` | force-rebuild flag / too-few-samples flag / NSS reduction |

Config struct (`*DAT_001081e0`): `+0x00` mode (0 auto, 1 fixed index, 5 fixed code), `+0x0b` basic-rate code, `+0x11` tick divisor, `+0x24` force-rebuild, **`+0x25` minimum attempts**, `+0x26/+0x27` retry counts, **`+0x29` probe step**, `+0x2a` down-step, `+0x2d` build counter.

## 3. Every function touching this state

All of it is one module (`rate_control.c`, 0x12c27a–0x12d710):

| addr | line | role |
|---|---|---|
| `FUN_0012c27a` | 33603 | NSS reduction; can clamp chain[0] up to `+0xa6`. Reads `+0x1b4`, `+0xa6`, `+0x1be` |
| **`FUN_0012c338`** | 33642 | **rate selection** (argmax + the down-step fallback); clears all per-rate stats |
| `thunk_FUN_0012d710` @0x12c474 | 33714 | byte-identical duplicate of `FUN_0012d710` |
| **`FUN_0012c478`** | 33853 | **retry-chain builder**; state 2 puts `cur + config[0x29]` at chain[0] |
| `FUN_0012c672/684/696/6a4/6b2/6fe` | 33996-34041 | getters (RSSI, success %, ctx ptr, counters) |
| `FUN_0012c714` | 34056 | returns `&rate_table[list[+0xaa]]` — the rate the host displays |
| **`FUN_0012c740`** | 34068 | **the state machine** |
| `FUN_0012c8c8` | 34192 | "is rate code supported" (reads `+0x08`) |
| `FUN_0012c900` | 34210 | chain indices → HW rate codes, BW bits, AMPDU duration cap |
| **`FUN_0012cc50`** | 34363 | **per-VIF periodic tick**: rebuild if flagged, call `FUN_0012d710` every `config[0x11]` ticks |
| `FUN_0012cf84` / `FUN_0012d012` | 34533/34564 | fixed-rate modes |
| `FUN_0012d124` | 34582 | zero the whole `rc_sta` (STA delete, from `FUN_001388b8` L42537) |
| `FUN_0012d15a` | 34598 | push chain to HW via ROM `func_0x000c8f92` |
| `FUN_0012d1e8`/`FUN_0012d24e` | 34638/34656 | set bits in `rc_sta+1` |
| **`FUN_0012d284`** | 34674 | build the ladder |
| **`FUN_0012d710`** | 34899 | **collect HW TX stats → per-rate EWMA → call `FUN_0012c740`** |
| `FUN_0012359a` / `FUN_001235f2` | 26526/26551 | HE DCM/ER admission helpers (read the table) |

Callers of `FUN_0012d284` outside the module: `FUN_001162da` L14814 (ap_ctrl STA add), `FUN_0011c186` L20441 (ap_frame), `FUN_00128e48` L31286. Periodic entry: `FUN_00139edc` L43396 → `FUN_0012cc50`. Trace module id **0x30**, events **0x5485** (selection, `FUN_0012c338` L33703) and **0x548b** (per-rate stats, `FUN_0012d710` L35001) — enabling firmware trace 0x30 would show every decision.

## 4. The key question: down vs. up

**Both directions exist. They are grossly asymmetric, and there are three specific ways the up path dies.**

### Down (immediate, unconditional, every period)

`FUN_0012c338` L33667-33683 scores each ladder index with `metric = EWMA_success% × rate_Mbps`, but **only for indices with `attempts >= config[0x25]`** (L33669) — an index that is not in the retry chain is invisible. Then L33690-33701:

```
if ((uVar9 & 0xff) == 0x1c) {           /* nothing had metric > 0 */
    uVar9 = uVar10;                      /* lowest index whose metric was 0 */
    if ((uVar10 & 0xff) != 0) uVar9 = uVar10 - 1;   /* → one step DOWN */
```

`FUN_0012c740` case 1 applies it at L34129 with no hysteresis, no dwell timer, no counter. **One step down per rate-control period, every period.**

### Up

* L34129 (best > cur) — but a higher index can only be "best" if it already has `>= config[0x25]` attempts, which only happens during a probe.
* The probe: case 1 → `LAB_0012c82e` → state 2; `FUN_0012c478` L33889-33898 sets `chain[0] = min(cur + config[0x29], +0xa4)`. Evaluated in case 2 L34141, which **only raises**. The cycle is 1→2→3→2→3→2→1, i.e. **6 periods per single +1 step** (vs. 1 period per −1 step).
* `FUN_0012c740` case 0 (jump back to `+0xa4 − 1`) — only after a full `FUN_0012d284` rebuild.

### Asymmetry #1 — the probe gate (L34120-34126)

```
34120  if (local_11 == *(byte *)(iVar5 + 0xa4)) return;      // at top: nothing to do
34123  if (*(char *)(iVar5 + 0x1a9) != '\0') {
34124      *(char *)(iVar5 + 0x1a9) = *(char *)(iVar5 + 0x1a9) + -1;
34125      return;                                            // probe suppressed
```

`+0x1a9` is loaded on every *failed* probe (L34146-34155):

```
34146  bVar2 = *(byte *)(iVar5 + 0x1a8);
34147  if (bVar2 != 6) bVar2 = bVar2 + 1;      // exponent, saturates at 6
34151  cVar3 = (char)(1 << (uint)bVar2) + *(char *)(iVar5 + 0x1a9);
```

Consecutive failed probes therefore space the next probe by **2, 4, 8, 16, 32, 64, 64, 64 …** periods, and `+0x1a9` is decremented **only** in state 1 — which only runs when `FUN_0012d710` saw TX activity (`if (local_8c[0] != '\0' || local_58 != '\0')`, L34940). **With no traffic the state machine is frozen entirely; that is why 45 s of idle changes nothing.**

### Asymmetry #2 — the two RSSI escape hatches are unreachable on a strong link

`FUN_0012d710` L35012-35015 (and the ch1 copy L35022-25):

```
if ((*(char *)(iVar11 + 0x1a6) + 3 < (int)cVar10) &&
   (*(undefined2 *)(iVar11 + 0x1a8) = 0, *(char *)(iVar11 + 0x1a6) + 0x14 < (int)cVar10)) {
    *(undefined1 *)(iVar11 + 0x1bc) = 1;     // force full rate-table rebuild
}
```

The backoff reset needs RSSI to **improve by >3 dB**; the forced rebuild needs **>20 dB**. There is **no** corresponding action on an RSSI *drop*. At a stable −33 dBm neither can ever fire — the link is already at the ceiling. So the only remaining up path is the probe.
(Also a genuine copy/paste defect in the second block, L35022-35026: the +3 dB test reads `+0x1a6` but the +20 dB test and the store use `+0x1a7`.)

### Asymmetry #3 — the hard latch: `+0xa4 == 0`

L34120: `if (local_11 == *(byte *)(iVar5 + 0xa4)) return;` — when the ladder has **one entry**, `best == cur == 0 == +0xa4` on every single period, so the function returns before `LAB_0012c82e`. **State never leaves 1, no probe is ever armed, `+0xaa` is pinned at 0 forever.**

And a one-entry ladder is exactly a 6.0 Mbit/s ladder: for a STA with any HE capability, L34763-65 deletes OFDM 9-54, HT is excluded (`sta[0xc]&7 != 1`), VHT is excluded (`&6 != 2`), CCK is excluded in 5 GHz — so if the HE per-NSS map `rc_sta+0x16` reads 3 ("not supported") when `FUN_0012d284` runs, **every** HE entry is dropped at L34816 and the survivor set is `{code 0x30, 6 Mbit/s}` → `+0xa4 = 0` (L34879). Nothing in the module can recover from that; only another `FUN_0012d284` with a valid MCS map (i.e. re-association) can. This is the only mechanism I found that produces literally "never", at exactly 6.0 Mbit/s OFDM, cleared only by re-association.

### The remaining candidate I cannot resolve: `config[0x29] == 0`

`config[0x29]` does double duty — it is both the **probe step** (L33890 `uVar13 = config[0x29] + cur`) and the **number of top-rate slots in the chain** (L33904, L33959). If a build sets it to 0, `chain[0] = cur + 0 = cur`: the probe becomes a no-op, `+0xaa < local_11` at L34141 can never be true, and the ladder can only ever go down. That is textbook "an upward path gated behind a condition that can never become true".

**I cannot read this value.** `DAT_001081e0` is a pointer at 0x001081E0 that reads **0x00000000** in `SWT6621S_IRAM_SDIO.bin`, and no function in either decompiled image writes it — it is installed by **ROM** (`func_0x000cXXXX`, below the 0x00100000 load base). I searched both binaries for the struct by field constraints and found no unambiguous match. So `config[0x25]` (min attempts), `config[0x29]` (probe step), `config[0x11]` (period), `config[0x26/0x27/0x2a]` are all **invisible**.

## 5. Thresholds, counters, timers

| gate | where | effect |
|---|---|---|
| `config[0x11]` | `FUN_0012cc50` L34425-34431 | `FUN_0012d710` (stats + decision) runs once per N VIF ticks |
| TX activity | `FUN_0012d710` L34940 | **no TX ⇒ no stats ⇒ the whole state machine is frozen** |
| `config[0x25]` | `FUN_0012c338` L33669 | a rate with fewer attempts is invisible to selection |
| EWMA | `FUN_0012d710` L34990-34998 | first 8 samples = running mean; then `pct/8 + 7·prev/8`; sticky flag `+0xc1` |
| stats reset | `FUN_0012c338` L33706-08 | all 28 slots cleared on every decision (`best != 0x1c`) |
| `+0x1b5` (0→3) | `FUN_0012c740` L34135-34162 | 6 periods per probe cycle |
| `+0x1a8`/`+0x1a9` | L34146-34155 / L34123-26 | exponential probe suppression, 2→64 periods, exponent capped at 6 |
| `+0xa4` | L34120 | at-top ⇒ unconditional early return (the hard latch) |
| RSSI +3 dB / +20 dB | L35012-35025 | reset backoff / force rebuild — unreachable at −33 dBm |
| RSSI < −34 dBm | L34106-34108 | on rebuild, start at `+0xa4>>1` instead of `+0xa4−1` |
| `config[0x24]` / `+0x1bc` | `FUN_0012cc50` L34399-34406, L34472-34476 | force a full ladder rebuild — the *only* jump back to the top |

## 6. Secondary defects found (real, but not the reported symptom)

* **`FUN_0012d284` never clears the per-rate statistics** (`+0xbc..+0x19b`); only `FUN_0012d124` (STA delete) does. `FUN_0012c338` scans all 28 slots regardless of `+0xa4`, so after a rebuild that *shrinks* the ladder, a stale slot can win and `+0xaa` is set beyond `+0xa4`. `FUN_0012c478` clamps chain[1..6] to `+0xa4` (L33971-73) but **not chain[0]** (L33938) and `FUN_0012c714` does not clamp either — the STA then transmits at, and reports, `rate_table[0]` = **1 Mbit/s DSSS**.
* **`FUN_0012c478` non-probe chain when `cur == 0`**: `uVar7` is used both as the "still descending" sentinel (0xFFFFFFFF) and as a position, and it is initialised to `chain[0]` (L33939-43). With `chain[0] == 0` the descending branch is never taken and the chain is built *ascending* — `[0, 1, 2, …]` (L33960).
* `FUN_0012c740` L34115-34117 / L34121 / L34125 return without calling `FUN_0012d15a`, so the HW policy table keeps the previous chain — benign but means a suppressed period does nothing at all.

## 7. Confidence

* **High** (directly read from code + verified against the extracted rate table and the host reporting path): the role of `FUN_0012d284`; the ladder layout and that 6.0 Mbit/s OFDM = index 0 for an HE 5 GHz STA; the full state machine; the fact that lowering is 1 step/period unconditional while raising is 1 step per 6 periods behind an exponentially growing suppression counter; the `+0xa4 == 0` hard latch at L34120; both RSSI escape hatches being unreachable at −33 dBm; the frozen-while-idle behaviour.
* **Medium**: that the specific stuck instance is the one-entry-ladder latch. The mechanism is exact and matches every observed detail (exactly 6.0 Mbit/s OFDM, never recovers, only re-association clears it), but the input that would trigger it — `rc_sta+0x16` (HE MCS map) or `sta_info[0xc]` reading as non-HE at rebuild time — is written by ROM and I cannot see it.
* **Unresolved / invisible**: everything behind `DAT_001081e0`. `config[0x29] == 0` would independently disable all upward probing and is equally consistent with the symptom. The struct is installed by ROM below 0x00100000, which is not in either binary. Also opaque: `func_0x000c78f0` (HW TX stats source), `func_0x000c8f92` (rate policy programming), `func_0x000c235c` (rate code → bitmap bit), `func_0x000d3864`/`func_0x000d3a68` (sta lookup), `func_0x000c5028` (max NSS), `func_0x000c8888` (NSS set), `func_0x000c8c48`.

Two things that would settle it without more RE: (a) enable firmware trace module **0x30** and watch events 0x5485/0x548b to see whether a probe ever gets programmed and what `+0xa4` is; (b) the host command interface reachable from `FUN_00122724` — **cmd 0x50** writes `config[0x2c]` and sets `config[0x24] = 1`, which makes `FUN_0012cc50` (L34401) run a full `FUN_0012d284` rebuild — i.e. it reproduces exactly what re-association does, and would confirm/serve as a workaround. **Cmd 0x51** (5 bytes) writes `config[0x2a], config[0x29], config[0x2b], config[0x26], config[0x27]` — that is the direct way to read back / force a non-zero probe step.
