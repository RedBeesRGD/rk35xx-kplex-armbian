#!/usr/bin/env bash
# Build a flash-and-go Armbian image for any board under firmware/. A stock Armbian rk35xx (ROCK 2F)
# image is the donor of kernel/rootfs/boot plumbing; everything board-specific — the loader pair, the
# device tree, the payload, DKMS sources — is baked in from firmware/<board>/.
#
# Usage:  ./build-image.sh  Armbian_rk35xx.img[.xz]  <board>  [out.img]
#   Run without <board> to list what's available. Default output is "<base>-<board>.img".
#   brew install e2tools xz    (macOS)   /   apt install e2tools xz-utils  (Linux)

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
FW="$REPO/firmware"

boards() { for d in "$FW"/*/board.conf; do [ -f "$d" ] && basename "$(dirname "$d")"; done | tr '\n' ' '; }
usage() { echo "usage: build-image.sh Armbian_rk35xx.img[.xz] <board> [out.img]"; echo "boards: $(boards)"; exit 1; }

BASE="${1:-}"; BOARD="${2:-}"
[ -n "$BASE" ] && [ -n "$BOARD" ] || usage
[ -f "$FW/$BOARD/board.conf" ] || { echo "Unknown board '$BOARD'"; echo "boards: $(boards)"; exit 1; }
# shellcheck source=/dev/null
. "$FW/$BOARD/board.conf"

if [ -n "${3:-}" ]; then OUT="$3"; else
  base_noext="${BASE%.xz}"; OUT="${base_noext%.img}-$BOARD.img"
fi

IDBLOADER="$FW/$BOARD_IDBLOADER"          # -> sector 64
UBOOT="$FW/$BOARD_UBOOT"                  # -> sector 16384
DTB="$FW/$BOARD_DTB"
PAYLOAD="$FW/$BOARD_PAYLOAD"
IDBLOADER_SEEK=64
UBOOT_PART_END=24575          # the factory uboot partition; the rootfs has to start above it
UBOOT_SEEK=16384
UBOOT_SLOT_SECTORS=4096
UBOOT_COPIES=2                # the uboot partition is two slots; both get the same FIT
# The BootROM scans five idbloader slots 1024 sectors apart. Every copy in a factory blob is
# byte-identical, so each slot gets the first one — the R69's blob only fills two of the five.
IDBLOADER_COPIES=5
IDBLOADER_COPY_SECTORS=1024
FACTORY_WINDOW_SEEK=7168      # DVKR at 7168 and SSKR at 8192, up to the uboot partition
FACTORY_WINDOW_SECTORS=9216
ROOTFS_START_MAX=131072       # 64 MiB: no Armbian layout starts further out, so a larger read is a bad GPT

# first partition's start LBA, read out of the GPT — the window must stop short of it
gpt_first_lba() {
  [ "$(dd if="$1" bs=1 skip=512 count=8 2>/dev/null)" = "EFI PART" ] ||
    { echo "no GPT in $1 — refusing to guess where the rootfs starts" >&2; return 1; }
  local parray
  parray=$(od -An -tu8 -j $((512 + 72)) -N 8 "$1" | tr -d ' ')
  case "$parray" in ''|*[!0-9]*|0) echo "GPT header names no partition array in $1" >&2; return 1 ;; esac
  od -An -tu8 -j $((parray * 512 + 32)) -N 8 "$1" | tr -d ' '
}
# Serial console on ff9f0000, never Armbian's stock ttyS2 (= a data UART on these boards). Boards
# that keep the vendor's fiq-debugger reach the same UART as ttyFIQ0 and set BOARD_SERIALCON.
SERIALCON="${BOARD_SERIALCON:-earlycon=uart8250,mmio32,0xff9f0000 console=ttyS0,1500000}"
# the in-kernel rockchip_pwm_remotectl lacks the shared-IRQ fix: it storms the group IRQ and drops
# IR wake, so our patched module owns the receiver instead
IR_BLACKLIST="${BOARD_IR_BLACKLIST-initcall_blacklist=rk_pwm_driver_init}"
BOARD_CMA="${BOARD_CMA:-256M}"   # the tree reserves 8 MiB, too little for one 4K frame
BOARD_NAME_FILE="$FW/$BOARD/board-name"   # same file the apt hook restores from

# ---- helpers ------------------------------------------------------------------------
fit_magic() { od -An -tx1 -N4 "$1" | tr -d ' \n'; }

# write $1 into $2 slots of $3 sectors from sector $4, each slot cleared first so nothing of what
# was under it survives behind a shorter blob
replicate() {
  local src=$1 copies=$2 sectors=$3 seek=$4 i=0 at
  while [ "$i" -lt "$copies" ]; do
    at=$((seek + i * sectors))
    dd if=/dev/zero of="$OUT" bs=512 seek="$at" count="$sectors" conv=notrunc 2>/dev/null
    dd if="$src"    of="$OUT" bs=512 seek="$at" count="$sectors" conv=notrunc 2>/dev/null
    i=$((i + 1))
  done
}


# ---- preflight: everything checked before the first byte is written -------------------
PAYLOAD_SRCS="$(sed -E 's/^[[:space:]]*#.*//; /^[[:space:]]*$/d' "$PAYLOAD" | awk '{print $2}')"
for f in "$BASE" "$IDBLOADER" "$UBOOT" "$DTB" "$PAYLOAD" "$BOARD_NAME_FILE" "$FW/common/fetch-dkms-src.sh"; do
  [ -f "$f" ] || { echo "Missing: $f"; exit 1; }
done
for s in $PAYLOAD_SRCS; do
  [ -f "$FW/$s" ] || { echo "Missing payload source: firmware/$s"; exit 1; }
done

# the BootROM answers an RKNS ID block and nothing else; a truncated FIT does not boot
[ "$(dd if="$IDBLOADER" bs=4 count=1 2>/dev/null)" = RKNS ] ||
  { echo "$IDBLOADER is not an RKNS ID block"; exit 1; }
[ "$(wc -c < "$IDBLOADER")" -ge $((IDBLOADER_COPY_SECTORS * 512)) ] ||
  { echo "$IDBLOADER is shorter than the $((IDBLOADER_COPY_SECTORS / 2)) KiB slot it is written into"; exit 1; }
[ "$(fit_magic "$UBOOT")" = d00dfeed ] || { echo "$UBOOT is not a FIT"; exit 1; }
[ "$(wc -c < "$UBOOT")" -le $((UBOOT_SLOT_SECTORS * 512)) ] ||
  { echo "$UBOOT is $(wc -c < "$UBOOT") bytes, past the $((UBOOT_SLOT_SECTORS / 2)) KiB U-Boot slot"; exit 1; }

# patched e2tools only: stock e2rm corrupts an image on delete
E2DIR="$REPO/tools/e2tools"
PATH="$E2DIR:$PATH"
for t in e2cp e2ls e2ln e2mkdir e2rm; do
  [ -x "$E2DIR/$t" ] || { echo "Need patched e2tools ($t). Run: ./build-e2tools.sh"; exit 1; }
done
for t in curl patch tar; do
  command -v "$t" >/dev/null || { echo "Need $t (DKMS source fetch)"; exit 1; }
done

# ---- 1. base image -> OUT ------------------------------------------------------------
echo "[1/5] Writing base image -> $OUT"
case "$BASE" in
  *.xz) command -v xz >/dev/null || { echo "Need xz to decompress $BASE"; exit 1; }; xz -dc "$BASE" > "$OUT" ;;
  *)    cp "$BASE" "$OUT" ;;
esac

# ---- 2. factory bootloader (raw sectors, before the first partition) -----------------
ROOTFS_START="$(gpt_first_lba "$OUT")"
[ "$ROOTFS_START" -gt "$UBOOT_PART_END" ] && [ "$ROOTFS_START" -le "$ROOTFS_START_MAX" ] ||
  { echo "First partition at $ROOTFS_START is inside the loader window, or the GPT read is wrong"; exit 1; }

# FACTORY_DUMP supplies DVKR + SSKR, the per-unit data nothing else can. Full-image path only:
# armbian-install keeps them itself.
if [ -n "${FACTORY_DUMP:-}" ]; then
  [ -f "$FACTORY_DUMP" ] || { echo "FACTORY_DUMP not found: $FACTORY_DUMP"; exit 1; }
  # dd stops early and silently on a short file, restoring part of the window - a dump cut off by
  # the Loader's 32 MiB read cap is the way this happens
  [ "$(wc -c < "$FACTORY_DUMP")" -ge $(((FACTORY_WINDOW_SEEK + FACTORY_WINDOW_SECTORS) * 512)) ] ||
    { echo "FACTORY_DUMP is short: it does not reach the end of the vendor window"; exit 1; }
  # catches a dump from a different board *model* - the idbloader is model-generic, so nothing here
  # can tell one unit from another of the same model, and passing the wrong one stamps its MAC and
  # keys into the image. Compare the first slot only: that copy is what we write to all five, so it
  # matches whether the dump came from a factory box or an already-migrated one.
  cmp -s <(dd if="$FACTORY_DUMP" bs=512 skip="$IDBLOADER_SEEK" count="$IDBLOADER_COPY_SECTORS" 2>/dev/null) \
         <(dd if="$IDBLOADER" bs=512 count="$IDBLOADER_COPY_SECTORS" 2>/dev/null) ||
    { echo "FACTORY_DUMP is not from a $BOARD: its idbloader differs from $BOARD_IDBLOADER"; exit 1; }
  echo "      Restoring DVKR + SSKR @${FACTORY_WINDOW_SEEK} from $(basename "$FACTORY_DUMP")"
  dd if="$FACTORY_DUMP" of="$OUT" bs=512 skip="$FACTORY_WINDOW_SEEK" seek="$FACTORY_WINDOW_SEEK" \
     count="$FACTORY_WINDOW_SECTORS" conv=notrunc 2>/dev/null
fi

echo "[2/5] Overlaying $BOARD idbloader x${IDBLOADER_COPIES} @${IDBLOADER_SEEK} + uboot.itb x${UBOOT_COPIES} @${UBOOT_SEEK}"
replicate "$IDBLOADER" "$IDBLOADER_COPIES" "$IDBLOADER_COPY_SECTORS" "$IDBLOADER_SEEK"
replicate "$UBOOT"     "$UBOOT_COPIES"     "$UBOOT_SLOT_SECTORS"     "$UBOOT_SEEK"

# ---- 3. attach the image, find the Armbian rootfs partition --------------------------
echo "[3/5] Attaching image to reach the ext4 rootfs"
OS="$(uname -s)"
ATTACHED=""
detach() { [ -n "$ATTACHED" ] || return 0
  case "$OS" in Darwin) hdiutil detach "$ATTACHED" >/dev/null 2>&1 || true ;;
                Linux)  sudo losetup -d "$ATTACHED" 2>/dev/null || true ;; esac; }
trap detach EXIT

if [ "$OS" = Darwin ]; then
  ATTACHED="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$OUT" | head -1 | awk '{print $1}')"
  PART="$(diskutil list "$ATTACHED" | awk '/[0-9]+:/{p=$NF} END{print p}')"   # last partition = rootfs
  # buffered BLOCK node (not /dev/r…): libext2fs does unaligned I/O, which the raw char
  # node rejects. hdiutil hands the node to the attaching user (rw), so no sudo needed.
  FS="/dev/${PART}"
else
  ATTACHED="$(sudo losetup -fP --show "$OUT")"
  FS="$(lsblk -lnpo NAME "$ATTACHED" | tail -1)"
  # own the node so e2tools run unprivileged (root + user-owned /tmp scratch breaks e2cp copy-out)
  sudo chown "$(id -un)" "$FS"
fi
echo "      rootfs partition: $FS"

# every payload path assumes the ROCK 2F kernel, dtb-<ver> layout and module set
REL="$(mktemp)"
BASE_BOARD=""
e2cp "$FS:/etc/armbian-release" "$REL" 2>/dev/null && BASE_BOARD="$(sed -n 's/^BOARD=//p' "$REL" | tr -d '"' | tr -d '\r')"
rm -f "$REL"
if [ "$BASE_BOARD" != "${EXPECT_BASE_BOARD:-rock-2f}" ]; then
  echo "Base image is BOARD='${BASE_BOARD:-unknown}', expected '${EXPECT_BASE_BOARD:-rock-2f}'."
  echo "Use an Armbian ROCK 2F image, or set EXPECT_BASE_BOARD to override."
  exit 1
fi

# ---- 4. install the board device tree + console --------------------------------------
echo "[4/5] Installing $BOARD DTB + console"
VERDIR="$(e2ls "$FS:/boot" | tr -s ' \t' '\n' | grep '^dtb-' | head -1)"
[ -n "$VERDIR" ] || { echo "Could not find /boot/dtb-<ver> in the image"; exit 1; }
FDT="rockchip/board.dtb"
e2cp "$DTB" "$FS:/boot/$VERDIR/$FDT"

ENV="$(mktemp)"
e2cp "$FS:/boot/armbianEnv.txt" "$ENV"
# console=display drops boot.cmd's stray console=ttyS2; ours goes via extraargs. tty1 stays last,
# as boot.cmd puts it for console=both, so /dev/console is HDMI and serial still gets the kernel log.
grep -v -E '^fdtfile=|^extraargs=|^console=' "$ENV" > "$ENV.new" || true
EXTRAARGS="$(printf '%s cma=%s %s console=tty1' "$SERIALCON" "$BOARD_CMA" "$IR_BLACKLIST" | tr -s ' ')"
printf 'fdtfile=%s\nconsole=display\nextraargs=%s\n' "$FDT" "$EXTRAARGS" >> "$ENV.new"
e2cp "$ENV.new" "$FS:/boot/armbianEnv.txt"
rm -f "$ENV" "$ENV.new"

# ---- 5. firmware payload + drop-ins + DKMS sources + rebrand -------------------------
echo "[5/5] Installing $BOARD payload + DKMS sources + rebrand"
TMP="$(mktemp -d)"

# --- static payload: every file from the board's payload.list, verbatim ---
while read -r mode src dest; do
  case "$mode" in ''|\#*) continue ;; esac
  e2mkdir "$FS:$(dirname "$dest")" 2>/dev/null || true
  e2cp -P "$mode" "$FW/$src" "$FS:$dest"
done < "$PAYLOAD"

# --- enable the board's oneshots without a wants/ symlink (e2tools can't symlink) ---
printf '[Unit]\nWants=%s\n' "$BOARD_WANTS" > "$TMP/10-$BOARD_HOSTNAME.conf"
e2mkdir "$FS:/etc/systemd/system/multi-user.target.d" 2>/dev/null || true
e2cp "$TMP/10-$BOARD_HOSTNAME.conf" "$FS:/etc/systemd/system/multi-user.target.d/10-$BOARD_HOSTNAME.conf"

# a board that disables the vendor fiq-debugger never gets /dev/ttyFIQ0, so the base's getty waits
# out a 90 s timeout every boot; one that keeps it needs that unit
case "$SERIALCON" in
  *ttyFIQ0*) echo "      keeping the base's serial-getty@ttyFIQ0 (this board's console)" ;;
  *) for u in /etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service \
            /etc/systemd/system/serial-getty@ttyFIQ0.service; do
       e2rm "$FS:$u" 2>/dev/null || true              # the same pair rk35xx-update removes
     done ;;
esac

# --- board-specific drop-ins + DKMS source staging (hooks from board.conf) ---
board_image_tweaks "$FS" "$TMP"
DKMSTMP="$(mktemp -d)"
board_stage_dkms "$FS" "$DKMSTMP"
rm -rf "$DKMSTMP"

# --- Bluetooth AutoEnable — only if the base already ships bluez (gate on non-empty copy) ---
BTMAIN="$(mktemp)"
if e2cp "$FS:/etc/bluetooth/main.conf" "$BTMAIN" 2>/dev/null && [ -s "$BTMAIN" ]; then
  if grep -qiE '^[[:space:]]*#?[[:space:]]*AutoEnable=' "$BTMAIN"; then
    sed -E 's/^[[:space:]]*#?[[:space:]]*AutoEnable=.*/AutoEnable=true/' "$BTMAIN" > "$BTMAIN.new"
  else
    cp "$BTMAIN" "$BTMAIN.new"; printf '\n[Policy]\nAutoEnable=true\n' >> "$BTMAIN.new"
  fi
  e2cp "$BTMAIN.new" "$FS:/etc/bluetooth/main.conf"
fi
rm -f "$BTMAIN" "$BTMAIN.new"

# ---- rebrand: the ROCK 2F base ships hostname "rock-2f" ------------------------------
e2cp "$FS:/etc/hostname" "$TMP/oldhost" 2>/dev/null || true
OLDH="$(tr -d '[:space:]' < "$TMP/oldhost" 2>/dev/null)"
printf '%s\n' "$BOARD_HOSTNAME" > "$TMP/hostname"
e2cp "$TMP/hostname" "$FS:/etc/hostname"
if [ -n "$OLDH" ] && e2cp "$FS:/etc/hosts" "$TMP/hosts" 2>/dev/null; then
  sed "s/$OLDH/$BOARD_HOSTNAME/g" "$TMP/hosts" > "$TMP/hosts.new"
  e2cp "$TMP/hosts.new" "$FS:/etc/hosts"
fi
# relabel the login MOTD board name (display only; BOARD= identifier stays for armbian tooling)
if e2cp "$FS:/etc/armbian-release" "$TMP/arel" 2>/dev/null; then
  sed "s/^BOARD_NAME=.*/BOARD_NAME=\"$(cat "$BOARD_NAME_FILE")\"/" "$TMP/arel" > "$TMP/arel.new"
  e2cp "$TMP/arel.new" "$FS:/etc/armbian-release"
fi
rm -rf "$TMP"

# --- verify we didn't corrupt the rootfs (e2tools writes ext4 without a kernel) --------
# (homebrew keeps e2fsprogs keg-only, so look in its opt prefix too)
FSCK="$(command -v fsck.ext4 || true)"
if [ -z "$FSCK" ]; then
  for c in /opt/homebrew/opt/e2fsprogs/sbin/fsck.ext4 /usr/local/opt/e2fsprogs/sbin/fsck.ext4; do
    if [ -x "$c" ]; then FSCK="$c"; break; fi
  done
fi
if [ -n "$FSCK" ]; then
  echo "      checking filesystem"
  "$FSCK" -fn "$FS" >/dev/null 2>&1 || {
    echo "FILESYSTEM CORRUPT — refusing to ship this image. Run: $FSCK -fn $FS"; exit 1; }
else
  echo "      (no fsck.ext4 found — filesystem NOT verified; brew install e2fsprogs)"
fi

detach; ATTACHED=""; sync
echo
echo "Done -> $OUT"
echo "Flash it (with progress):"
echo "  macOS:  diskutil unmountDisk /dev/diskN; sudo gdd if=$OUT of=/dev/rdiskN bs=4M conv=fsync status=progress   (brew install coreutils)"
echo "  Linux:  sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"
echo "  ...or Balena Etcher on either OS."
