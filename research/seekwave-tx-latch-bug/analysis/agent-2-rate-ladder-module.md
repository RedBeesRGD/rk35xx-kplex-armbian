# Agent report — rate-adaptation machinery (everything except FUN_0012d284)

Verbatim subagent output. Scope: map the rate-control module, find the ladder, find the reset path.

---

# Rate-adaptation machinery in SWT6621S firmware (everything except FUN_0012d284)

## 1. Where it lives

`s_rate_control_c_001406e2` is referenced **only** by FUN_0012d284, but the whole `rate_control.c` object is contiguous in flash. I identified it by the per-station context array `0x202233b4[sta_idx]`, which is referenced **nowhere else in the 64k-line image**:

| Addr | decomp.c | Role |
|---|---|---|
| `FUN_0012c27a` | 33603 | Bandwidth-fallback clamp (returns possibly-clamped rate idx) |
| **`FUN_0012c338`** | **33642** | **Rate chooser — argmax(EWMA_pct × rate_mbps); also the down-shift-on-failure path** |
| **`FUN_0012c478`** | **33853** | **Builds the 8-entry retry/rate chain; contains the up-probe rate** |
| `FUN_0012c672/684/696/6a4/6fe/714` | 33996-34068 | Getters (RSSI 0x1a6, success% 0x1a4, ctx ptr, counters, current rate entry) |
| **`FUN_0012c740`** | **34068** | **THE LADDER STATE MACHINE (4 states). Only writer of the current rate index 0xaa** |
| `FUN_0012c8c8` | 34192 | per-STA capability bit test |
| `FUN_0012c900` | 34210 | Chain → HW rate codes / preamble / length-limit |
| **`FUN_0012cc50`** | **34363** | **Periodic per-VIF tick; drives the RC interval counter, computes success%** |
| `FUN_0012cf84` | 34533 | Fixed-rate mode (cfg mode 5) |
| `FUN_0012d012` | 34564 | Fixed-rate override programming |
| **`FUN_0012d124`** | **34582** | **`memset(rc_ctx, 0, 0x1e0)` — full RC context wipe (vif create)** |
| `FUN_0012d15a` | 34598 | Programs the rate LUT to HW (`func_0x000c8f92`, ROM) |
| `FUN_0012d1e8 / 0012d24e` | 34638/34656 | per-STA flag setters (SGI / LDPC-ish) |
| `FUN_0012d284` | 34674 | *(other agent)* rate-table build + reset |
| **`FUN_0012d710`** | **34899** | **Statistics collector: pulls per-chain-slot TX counters from ROM, EWMA, then calls the ladder** |

`thunk_FUN_0012d710 @ 0012c474` (line 33714) is a byte-identical duplicate of FUN_0012d710 used by the beacon path.

**All TX-rate programming to hardware goes through `func_0x000c8f92` (ROM), called only from FUN_0012d15a and FUN_0012d012.** There is no second rate selector anywhere in the image (verified by cross-referencing the global rate table `0x20217ce0` and the ctx array — both are confined to `0x12c27a..0x12d710`). The only EWMA in the whole file is in FUN_0012d710.

## 2. Data layout (recovered)

**Global rate table @ `0x20217ce0`, 57 entries × 6 bytes** — I dumped it from `fw/SWT6621S_DRAM_SDIO.bin` (DRAM base = `0x20200000`, verified):
`{u8 idx, u8 hw_rate_code, u8 mode, u8 divisor, u16 rate_mbps}`, sorted ascending by rate.
mode 0 = DSSS/CCK (codes 0x10-0x13, 0x20-0x23), **mode 1 = legacy OFDM (codes 0x30..0x37 = 6,9,12,18,24,36,48,54 Mbps — global index 9 = code 0x30 = the stuck 6.0 Mbps)**, mode 2 = HT20, mode 3 = VHT20, mode 4 = HE20 MCS0-11 (max 143 Mbps @ idx 56), modes 5-7 = HE variants.

**Per-station RC context** (`ctx = *(int*)(0x202233b4 + sta_idx*4)`, size 0x1e0):

| off | meaning |
|---|---|
| `0x18..0xa3` | rate table: **28 entries × 5 bytes**, `[0]` = index into global table. Ascending |
| `0xa4` | **max valid rate index** (n_entries-1) |
| `0xa6` | bandwidth-fallback rate-index threshold (0x1c = none) |
| `0xa7` | success-% window counter |
| `0xa8/0xa9` | LUT generation seq |
| **`0xaa`** | **CURRENT RATE INDEX** ← the observable "TX rate" |
| `0xab..0xb2` | active retry/rate chain (8 slots) |
| `0xb3..0xba` | copy of chain (second stats set) |
| `0xbc + 8*i` | per-rate stats: `+0` u32 attempts, `+4` u8 sample count, `+5` u8 warmup-done, **`+6` u8 EWMA success %** (so index 27 lands at 0x194/0x19a) |
| `0x19c/0x1a0` | total attempts / successes accumulators |
| `0x1a4` | success percentage (reported to host) |
| `0x1a6/0x1a7` | avg RSSI (primary/secondary) |
| **`0x1a8`** | **probe backoff exponent (cap 6)** |
| **`0x1a9`** | **probe backoff countdown (signed char)** |
| `0x1ba` | RC interval tick counter |
| `0x1bc` | "rebuild rate table" request |
| `0x1bd` | "few eligible rates" robustness flag |
| **`0x1b4`** | **ladder state: 0=init, 1=normal, 2=probe-active, 3=probe-idle** |
| `0x1b5` | probe phase counter |
| `0x1be` | bandwidth-downgrade depth |

Global config struct `*DAT_001081e0`: `[0]`=mode(0 auto/1 fixed idx/5 fixed rate), `[0x11]`=**RC evaluation interval in ticks**, `[0x1c]`=success-% window, `[0x24]`=force-rebuild, **`[0x25]`=min attempts for a rate to be a candidate**, `[0x26]/[0x27]`=retry counts, **`[0x29]`=probe step (also #fine-grained chain steps)**, `[0x2a]`=chain step-down, `[0x2d]`=peer count. Tunable from the host by vendor command 0x51 (FUN_00122724, line 25630).

## 3. There IS an up-shift path — but it is the *only* one, and it is gated

### Down-shifts (every interval, cheap)
`FUN_0012c338` (33642) scans all 28 slots high→low:
```c
33661:  bVar1 = *(byte *)(DAT_001081e0 + 0x25);           // min attempts
33669:    if ((uint)bVar1 <= *(uint *)(iVar4 + 0x194)) {  // candidate must have attempts
33670:      uVar5 = (uint)*(byte *)(iVar4 + 0x19a);       // EWMA success %
33672:      uVar6 = uVar5 * *(ushort *)(... + 0x20217ce4);// pct * rate_mbps = throughput est
33674:        uVar9 = iVar2 + 0x1bU;                      // best index
33678:        uVar10 = iVar2 + 0x1bU;                     // lowest index with ZERO throughput
```
then, if nothing scored:
```c
33693:  if ((uVar9 & 0xff) == 0x1c) {
33694:    uVar9 = uVar10;
33695:    if ((uVar10 & 0xff) != 0) { uVar9 = uVar10 - 1; }   // <-- STEP DOWN
33699:      *(undefined1 *)(iVar7 + 0x1bd) = 1;              // <4 candidates -> robustness flag
33707:    FUN_0013dfae(iVar7 + 0xbc,0xe0);                   // <-- WIPES ALL 28 PER-RATE STATS
```
**Line 33707 is structurally decisive**: every decision erases the statistics of every rate. Between decisions only the rates present in the current retry chain accrue stats, and in state 1 the chain contains only the current rate and lower ones (FUN_0012c478 line 33933 + descending loop). **Therefore in the normal state the selector can only stay put or move DOWN.** The user's hypothesis is correct as far as steady-state operation goes.

### The up-shift: a probe state machine
`FUN_0012c740` (34068):
```c
34097:  uVar1 = *(undefined1 *)(iVar5 + 0x1b4);   // state
34100:  case 0:                                   // INIT
34101:    bVar2 = *(byte *)(iVar5 + 0xa4);        // max index
34103:      bVar4 = bVar2 - 1;                    // start at max-1
34105:    if (*(short *)((&DAT_001081e4)[param_1] + 0x4e) < -0x22) bVar4 = bVar2 >> 1;  // RSSI<-34dBm -> max/2
34108:    *(byte *)(iVar5 + 0xaa) = bVar4;        // -> state 1

34113:  case 1:                                   // NORMAL
34114:    FUN_0012c338(param_1,&local_11);
34115:    if (local_11 == 0x1c) return;           // no candidate -> NOTHING happens
34118:    if (bVar2 == local_11) {                // best == current
34120:      if (local_11 == *(byte *)(iVar5 + 0xa4)) return;   // at TOP -> never probe
34123:      if (*(char *)(iVar5 + 0x1a9) != '\0') {            // backoff pending
34124:        *(char *)(iVar5 + 0x1a9) = *(char *)(iVar5 + 0x1a9) + -1;
34125:        return; }
34128:    } else { *(byte *)(iVar5+0xaa) = local_11;
34129:             *(undefined2 *)(iVar5 + 0x1a8) = 0;         // clears BOTH 0x1a8 and 0x1a9
34130:             if (local_11 <= bVar2) goto default; }      // DOWN-shift: no probe
34133:    goto LAB_0012c82e;                                   // -> state 2 = PROBE

34134:  case 2:                                   // PROBE ACTIVE
34137:    if (2 < bVar2) {                        // after 3 probe rounds
34139:      FUN_0012c338(param_1,&local_11);
34141:      if (*(byte *)(iVar5 + 0xaa) < local_11) {  // probe won -> CLIMB
34142:        *(byte *)(iVar5 + 0xaa) = local_11;
34143:        *(undefined2 *)(iVar5 + 0x1a8) = 0;
34146:      } else {                                   // probe lost -> EXPONENTIAL BACKOFF
34147:        bVar2 = *(byte *)(iVar5 + 0x1a8);
34148:        if (bVar2 != 6) bVar2 = bVar2 + 1;       // exponent capped at 6
34151:        cVar3 = (char)(1 << (uint)bVar2) + *(char *)(iVar5 + 0x1a9);
34152:        if (*(char *)(iVar5 + 0x1a9) == -1) cVar3 = -1;
34155:        *(char *)(iVar5 + 0x1a9) = cVar3;        // += 2,4,8,16,32,64,64,...
```
and the actual probe rate is injected as chain slot 0 by `FUN_0012c478`:
```c
33889:    if (*(char *)(iVar8 + 0x1b4) == '\x02') {
33890:      uVar13 = *(byte *)((int)DAT_001081e0 + 0x29) + uVar13;   // current + cfg[0x29] = PROBE RATE
33891:      if (*(byte *)(iVar8 + 0xa4) < uVar13) uVar13 = *(byte *)(iVar8 + 0xa4);  // clamp to max
33895:      *(char *)(iVar8 + 0xab) = (char)uVar13;
```
States 2 and 3 alternate (`0x1b5` = 0,1,2) so 3 of 5 intervals carry the probe chain, then the verdict is taken.

**So: down = every interval; up = only via a 5-interval probe cycle that must beat the current rate on `EWMA_pct × rate` AND must have accumulated ≥ cfg[0x25] attempts, and is gated by an exponential backoff counter.**

### EWMA (FUN_0012d710, 34899)
```c
34939:    func_0x000c78f0(param_1,local_8c);                  // ROM: fetch per-chain-slot TX stats
34940:    if (local_8c[0] != '\0' || local_58 != '\0') {      // <-- gate: no stats => ladder never runs
34984:              uVar7 = (uVar6 * 100) / uVar5;            // success percent this window
34990:              if ((*(char *)(iVar4+0xc1) == '\0') && (uVar12 < 8)) {   // warm-up: running mean
34995:                cVar10 = ((byte)uVar7 >> 3) + (char)((uint)*(byte*)(iVar4+0xc2) * 7 >> 3);  // EWMA a=1/8
35031:      FUN_0012c740(param_1);                            // <-- the ONLY entry to the ladder
```

## 4. Periodic drivers

- `FUN_0012cc50` (34363) is the per-VIF RC tick; for each active peer:
  `34425: bVar1 = cfg[0x11]; 34427: sta[0x1ba]++; 34428: if (bVar1 <= sta[0x1ba]) FUN_0012d710(sta);` and every `cfg[0x1c]` ticks computes `sta[0x1a4] = 100*successes/attempts` (34436, **divides by `sta[0x19c]` without a zero check**).
  Callers: `FUN_00139edc` @ 43396 (sta.c periodic supervision) and `FUN_001157d8` @ 14199 (VIF event dispatcher, event id 4).
- `FUN_0013c40c` (45658) re-runs the collector on beacon reception (called from the beacon RX handler at 42805).
- Neither FUN_00139edc nor FUN_001157d8 has an in-image caller, and their addresses appear in no pointer table in either binary — **they are invoked from ROM**, so the absolute RC period is not determinable statically.

## 5. The reset — this is the association path

**`FUN_0012d284` is called from the association-response handler.** `FUN_001162da` (14695) is the management-frame RX path; line 14774 restricts to `subtype == 1 || subtype == 3` (Assoc Resp / Reassoc Resp), 14783 requires status == 0, 14790 validates the AID, then:
```c
14814:        FUN_0012d284(param_1,*(undefined1 *)(iVar5 + 8));   // rc init for the AP peer
```
Other call sites: `FUN_0011c186` @ 20441 (AP-side assoc req), `FUN_00128e48` @ 31286 (operating-mode/action frame), and `FUN_0012cc50` @ 34402/34463/34473 (periodic, when `cfg[0x24]` or `sta[0x1bc]` is set).

Without analysing it, its reset writes are (lines 34704-34707 and 34879-34887):
```c
34703:  FUN_0013dfae(iVar10 + 0x18,0x8c);        // clears the 28x5-byte rate TABLE
34704:  *(undefined1 *)(iVar10 + 0xa6) = 0x1c;   // bandwidth-fallback threshold
34705:  *(undefined1 *)(iVar10 + 0xa5) = 0x1c;
34706:  *(undefined1 *)(iVar10 + 0x1b5) = 0;     // probe phase counter
34707:  *(undefined2 *)(iVar10 + 0x1a8) = 0;     // PROBE BACKOFF exponent + countdown
34879:    *(byte *)(iVar12 + 0xa4) = bVar3 - 1;  // max rate index (rebuilt)
34881:  if (*(char *)(iVar12 + 0x1b4) == '\0') { ... *DAT_001081e0 = 0; }
34887:  else { *(undefined1 *)(iVar12 + 0x1b4) = 0; }   // STATE -> 0
34889:  FUN_0012c740(param_2);                   // -> case 0 -> 0xaa = max-1
```
**That is precisely why re-association fixes the bug**: state → 0 forces case 0, which *unconditionally jumps the rate index to `max-1`* without consulting any statistics. It also zeroes the probe backoff and rebuilds the table/max index. Note it does **not** clear the per-rate stats array (0xbc..0x19b).

So the stuck variable is one of: **`0x1b4`(state) / `0x1a8`+`0x1a9`(probe backoff) / `0xa4`(max index) / `0x1b5`**. `FUN_0012d124` (34582) is a second, harder reset (`memset(ctx,0,0x1e0)`), called only from VIF creation `FUN_001388b8` @ 42533.

## 6. Ranked latch candidates

1. **`0x1a9` probe backoff (highest confidence for "climbs never happen in practice")** — it is the only variable whose purpose is to suppress up-probes. Each lost probe adds `1<<min(exp,6)` (i.e. +64 once exp saturates) to a **signed char** decremented by 1 per RC interval, so one lost probe can suppress climbing for up to ~127-255 intervals, and each new probe re-arms it. A probe counts as "lost" whenever `FUN_0012c338` fails to return a strictly higher index — **including when the probe rate simply never reached `cfg[0x25]` attempts** (low offered load, which is exactly the situation when TX is stuck at 6 Mbps). It is cleared only by an actual rate change, by RSSI rising >3 dB *between two consecutive intervals* (34012-34013), or by FUN_0012d284. A slow RSSI recovery (<3 dB/interval) never clears it.
2. **`0xa4` max rate index too small** — line 34120 `if (local_11 == *(byte *)(iVar5 + 0xa4)) return;` makes the ladder return forever, with no probe, whenever the selected index equals the top of the table. If FUN_0012d284's rebuild ever produces a short/legacy-only table (it can be re-run from the periodic path at 34463/34473), you are permanently pinned at the top of a truncated ladder — which would be the lowest basic rates. Fits "only re-association clears it" perfectly. **`0xa4` is written only by FUN_0012d284 — please have the other agent check the entry-count path around line 34860-34879 (`if (0x1b < bVar3) goto LAB_0012d672;`).**
3. **Ladder never invoked** — FUN_0012d710 line 34940: if the ROM stats fetch returns both blocks empty, `FUN_0012c740` is never called at all and the rate is frozen in both directions.
4. **`cfg[0x29]` (probe step) == 0** → line 33890 computes `probe = current + 0`, i.e. the probe is a no-op and the ladder can never climb. Its default lives in ROM; the host can set it via vendor command 0x51 byte[1] (line 25631). Its dual use at 33904/33959 as a chain-shape count suggests it is normally 2-3, so this is the least likely of the four, but it is cheap to verify at runtime.

Secondary defects noticed (not the primary latch):
- **Copy/paste bug at 35022**: the secondary-chain RSSI block tests `sta[0x1a6] + 3` (primary RSSI) but stores/compares against `sta[0x1a7]`; the backoff-clear condition is evaluated against the wrong RSSI history.
- **`cfg[0x2d]` is incremented per first-time peer init (34882) and never decremented anywhere in this image**, so after the second peer ever registered, `FUN_0012c478` line 33985 `if (1 < cfg[0x2d])` permanently overwrites the tuned per-slot retry counts with the 0x04040404/0x07070704 defaults.
- **`FUN_0012c27a` (33603) bandwidth fallback**: when it downgrades bandwidth it also clamps the programmed rate index to `sta[0xa6]` (33634), and the restore call at 33622 re-reads the *current* bandwidth from `sta_info+0xc` — if the ROM setter `func_0x000c8888` mutates that field, the restore is a no-op and the bandwidth never comes back.
- **Division by zero risk** at 34436/34506 (`/ sta[0x19c]`) when a window elapses with no TX attempts.

## 7. Assert-symbol inventory (task item 1)

`s_hal_mac_tx_c_0010f44d`: FUN_0010a810, 0010afb8, 0010b29c, 0010b628, 0010b68c, 0010b984, 0010ba88, 0010bb44, 0010bbf0, 0010bc74, 0010bf00, 0010bf58, 0013d390. `s_machw_com_c`: FUN_0010c9da. `s_hw_lmac_tx_c`: FUN_0011e13c, 0013d8cc. `s_hw_hmac_tx_c`: FUN_00126ed4, 0013cf80, 0013d418. `s_machw_lut_c`: FUN_001268c0 (per-STA HW policy-LUT init, 9×u16 = 0x800, called on peer add from FUN_001388b8), FUN_00126a88. `s_mha_c`: FUN_00123c4a, 00123db4, 00123f10. `s_sta_c`: FUN_00139edc, 0013a6a0. `s_rate_control_c`: FUN_0012d284 only. There is no `tx_ctrl` or `peer_mgmt` assert reference in the image.
**None of these TX-path functions touch a rate index or the rate table** — verified by cross-referencing every use of `0x20217ce0` and `0x202233b4`.

## 8. Confidence / what is hidden in ROM

High confidence: the module map, the struct layout, the global rate table decode, the state machine semantics, and the fact that the *only* up-shift path is the state-2 probe gated by `0x1a9`. Medium confidence on which variable is actually latched — that requires runtime observation or the ROM.

Hidden in ROM (`func_0x000c****`, not in either binary):
- `func_0x000c78f0` — the actual per-chain-slot attempt/success counters and the "stats valid" byte that gates the whole ladder.
- `func_0x000c8f92` / `func_0x000c8f32` — the HW rate-LUT programming and stats reset.
- The initial values of the config struct `*DAT_001081e0` (probe step `[0x29]`, min attempts `[0x25]`, RC interval `[0x11]`) — the pointer at IRAM `0x001081e0` is zero in the image and is filled by ROM at init; the struct is in ROM-owned BSS.
- The scheduler/timer that calls `FUN_00139edc` / `FUN_001157d8`, so the wall-clock RC period is unknown.

Fastest runtime confirmation: dump `ctx = *(u32*)(0x202233b4 + sta_idx*4)` while the bug is active and read `ctx[0x1b4]` (expect 1), `ctx[0xaa]` (expect 0), `ctx[0xa4]` (if this is also 0 or equal to 0xaa → candidate 2 confirmed), and `ctx[0x1a8]/[0x1a9]` (if 0x1a8 == 6 and 0x1a9 is large → candidate 1 confirmed).
