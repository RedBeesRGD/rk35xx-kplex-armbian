# rkdeveloptool — patches

`rkdeveloptool pack` builds a maskrom loader, but only in the old RC4-on `BOOT` format. RK3528's
BootROM accepts that file over USB and then ignores it without a word. The format it answers is
new-IDB with RC4 off, magic `LDR `, which Rockchip's own `rkbin/RKBOOT/RK3528MINIALL.ini` asks for
through `[SYSTEM] NEWIDB=true` and `[FLAG] RC4_OFF=true` — sections the stock parser rejects
outright with `unknown sec: [SYSTEM]!`.

`../../build-rktools.sh` fetches rkdeveloptool, applies these, and builds to `tools/rktools/`. It
then packs each board's loader from that same rkbin ini, so the flags come from Rockchip's file
rather than from anything this repo invents.

| Patch  | Fixes                                                                       |
| ------ | --------------------------------------------------------------------------- |
| `0001` | `[SYSTEM]`/`[FLAG]` rejected; `LOADER<n>` off-by-one; tag and RC4 hardcoded |

`0001` also fixes an out-of-bounds write: `parseLoader` indexed `gOpts.loader[]` with the number in
the `LOADER<n>=` key, while `[CODE471_OPTION]` decrements it. Rockchip's 1-based `LOADER1`/`LOADER2`
therefore wrote one past a two-element array.

✅ Verified on the H96 Max 3518D, 2026-09-12, loader packed on macOS arm64: `db` succeeded, `rfi`
reported 30777344 sectors, and `rl 64 1024` came back byte-identical to the repo's factory
idbloader. The `UsbHead`/`FlashHead` entries that `CREATE_IDB=true` adds are not needed for this.
