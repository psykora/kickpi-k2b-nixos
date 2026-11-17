#!/usr/bin/env bash
# emmc-transfer-board.sh — runs ON THE BOARD (as root) from the running SD system.
# Partitions the internal eMMC and installs the eMMC-configured NixOS system
# that the host has already pushed into this system's /nix/store.
#
# Environment:
#   TOP          store path of the eMMC toplevel (config.system.build.toplevel of
#                sd-image-emmc.nix) — MUST already be present in /nix/store
#   REG          path to the closure registration file (nix-path-registration)
#   F2FS_TOOLS   store path of the f2fs-tools package (the running SD system has
#                no f2fs support built in; the host pushes the package)
#   DOSFSTOOLS   store path of the dosfstools package
#   RUN_POWER    =1 to power off when done (so you can remove the SD card)
#   CONFIRM_WIPE must be exactly "YES-WIPE-EMMC" to actually touch the disk
#
# Safety: the eMMC is identified by its model string (BJTD4R) AND by not being
# the device the running system boots from. Refuses on any ambiguity.
set -euo pipefail

: "${TOP:?TOP not set}"
: "${REG:?REG not set}"
: "${F2FS_TOOLS:?F2FS_TOOLS not set}"
: "${DOSFSTOOLS:?DOSFSTOOLS not set}"
CONFIRM_WIPE="${CONFIRM_WIPE:-}"

fail() { echo "FATAL: $*" >&2; exit 1; }

# clean leftovers from previous aborted attempts (they hold the device busy)
umount /mnt/emmc /mnt/emmc-boot 2>/dev/null || true

echo "=== 1. identify eMMC ==="
rootPart="$(findmnt -n -o SOURCE /)"
rootDev="$(lsblk -npo PKNAME "$rootPart")"
echo "running system: $rootPart on $rootDev"

# NB: MMC devices expose the CID product name via device/name (not device/model)
blockmodel() {
  local m=""
  [ -r "$1/device/name" ] && m=$(tr -d ' ' < "$1/device/name")
  if [ -z "$m" ] && [ -r "$1/device/model" ]; then m=$(tr -d ' ' < "$1/device/model"); fi
  echo "$m"
}

cand=()
for d in /sys/block/mmcblk*; do
  [ -e "$d" ] || continue
  dev="/dev/$(basename "$d")"
  [ "$dev" = "$rootDev" ] && continue
  case "$dev" in *boot*) continue ;; esac
  m=$(blockmodel "$d")
  size=$(cat "$d/size" 2>/dev/null || echo 0)  # in 512B sectors
  if [ "$m" = "BJTD4R" ] && [ "$size" -gt 40000000 ]; then
    cand+=("$dev")
  fi
done
# Fallback: no CID name matched — take the single non-root removable-class
# device bigger than 20 GiB.
if [ ${#cand[@]} -eq 0 ]; then
  for d in /sys/block/mmcblk*; do
    [ -e "$d" ] || continue
    dev="/dev/$(basename "$d")"
    [ "$dev" = "$rootDev" ] && continue
    case "$dev" in *boot*) continue ;; esac
    size=$(cat "$d/size" 2>/dev/null || echo 0)
    [ "$size" -gt 40000000 ] && cand+=("$dev")
  done
fi
[ ${#cand[@]} -eq 1 ] || fail "expected exactly 1 eMMC candidate, found: ${cand[*]:-none}"
EMMC="${cand[0]}"
echo "eMMC identified: $EMMC ($(blockdev --getsize64 "$EMMC") bytes, model $(blockmodel /sys/block/$(basename "$EMMC")))"

[ "$(basename "$rootPart" | sed 's/p[0-9]*$//')" != "$(basename "$EMMC")" ] \
  || fail "root device matches eMMC?!"
[ "$CONFIRM_WIPE" = "YES-WIPE-EMMC" ] || fail "set CONFIRM_WIPE=YES-WIPE-EMMC to proceed (this destroys all data on $EMMC)"

echo "=== 2. verify eMMC toplevel closure is in the local store ==="
nix-store -qR "$TOP" >/dev/null || fail "$TOP not in store — run 'nix copy' from the build host first"
echo "toplevel: $TOP"

echo "=== 3. write U-Boot + partition ==="
wipefs -a "$EMMC" 2>/dev/null || true   # erase any old table/signatures first
# U-Boot FIRST: copy 1 MiB of SPL+U-Boot from the SD card (offset 8 KiB there)
# to the eMMC gap at offset 8 KiB. (skip= input blocks, seek= output blocks!)
dd if="$rootDev" of="$EMMC" bs=1024 skip=8 seek=8 count=1024 conv=notrunc status=none
sync
sfdisk --no-reread "$EMMC" <<'EOF'
label: dos
start=16384, size=262144, type=0c
start=278528, type=83
EOF
blockdev --rereadpt "$EMMC"; udevadm settle
# Partition nodes may lag the re-scan (devtmpfs/udev race) — wait for them.
for i in $(seq 1 30); do
  [ -b "${EMMC}p1" ] && [ -b "${EMMC}p2" ] && break
  partx -a "$EMMC" 2>/dev/null || true
  udevadm settle || true
  sleep 1
done
[ -b "${EMMC}p1" ] && [ -b "${EMMC}p2" ] || fail "partition devices ${EMMC}p1/${EMMC}p2 never appeared"

echo "=== 4. format ==="
P1="${EMMC}p1"; P2="${EMMC}p2"
"$DOSFSTOOLS/bin/mkfs.vfat" -n EMMCBOOT -i 66666666 "$P1"
"$F2FS_TOOLS/bin/mkfs.f2fs" -f -t 0 -l NIXOS_EMMC -U 33333333-3333-3333-8888-888888888888 \
  -O extra_attr,inode_checksum,sb_checksum,compression "$P2"

echo "=== 5. copy nix store closure to f2fs root ==="
umount /mnt/emmc /mnt/emmc-boot 2>/dev/null || true   # leftovers from earlier attempts
mkdir -p /mnt/emmc /mnt/emmc-boot
mount "$P2" /mnt/emmc
# the f2fs root starts empty: create the store INSIDE the mounted fs
mkdir -p /mnt/emmc/nix/store
xargs -I % cp -a --reflink=auto % /mnt/emmc/nix/store/ < <(nix-store -qR "$TOP")
cp "$REG" /mnt/emmc/nix-path-registration
mkdir -p /mnt/emmc/nix/var/nix/profiles
ln -sfn "$TOP" /mnt/emmc/nix/var/nix/profiles/system

echo "=== 6. install boot files on FAT ==="
mount "$P1" /mnt/emmc-boot
k="$(readlink -f "$TOP/kernel")"
i="$(readlink -f "$TOP/initrd")"
d="$(readlink -f "$TOP/dtbs")"
mkdir -p /mnt/emmc-boot/extlinux /mnt/emmc-boot/nixos
cp "$k" /mnt/emmc-boot/nixos/"$(basename "$k")"
cp "$i" /mnt/emmc-boot/nixos/"$(basename "$i")"
cp -r "$d" /mnt/emmc-boot/nixos/"$(basename "$d")"
cat > /mnt/emmc-boot/extlinux/extlinux.conf <<EOF
# Generated by emmc-transfer-board.sh
DEFAULT nixos-default
TIMEOUT 50

LABEL nixos-default
  MENU LABEL NixOS - Default
  LINUX ../nixos/$(basename "$k")
  INITRD ../nixos/$(basename "$i")
  APPEND init=$TOP/init $(cat "$TOP/kernel-params")
  FDT ../nixos/$(basename "$d")/allwinner/sun50i-h618-kickpi-k2b.dtb
EOF
sync
umount /mnt/emmc-boot /mnt/emmc

echo "=== done: eMMC installed. ==="
if [ "${RUN_POWER:-0}" = "1" ]; then
  echo "powering off in 5s — remove the SD card after shutdown."
  sleep 5
  poweroff
else
  echo "remove the SD card and reboot into eMMC when ready."
fi
