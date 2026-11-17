#!/usr/bin/env bash
# emmc-transfer.sh — runs on the BUILD HOST. Drives the transfer of the running
# SD-card NixOS system to the board's internal eMMC:
#   1. builds the eMMC toplevel (sd-image-emmc.nix) locally
#   2. pushes the closure + registration + board script to the board over ssh
#   3. runs the destructive partition/format/copy on the board (emmc-transfer-board.sh)
#   4. powers the board off; remove the SD card, boot eMMC.
#
# Requirements: key-based ssh to admin@kickpi-k2b.lan + sudo NOPASSWD (enable
# security.sudo.wheelNeedsPassword + your ssh key in configuration.nix first).
# The board must be running (any state) — its current system is untouched
# except for /tmp.
#
# Usage:
#   ./emmc-transfer.sh            # does everything, powers off at the end
#   ./emmc-transfer.sh --no-poweroff
set -euo pipefail

cd "$(dirname "$0")"
BOARD="${DEPLOY_BOARD:-admin@kickpi-k2b.lan}"   # override with DEPLOY_BOARD=user@host
# nixpkgs: resolve via the host's channel; override with NIXPKGS=/path
NIXPKGS="${NIXPKGS:-$(nix-instantiate --find-file nixpkgs 2>/dev/null)}"
[ -n "$NIXPKGS" ] || { echo "cannot locate <nixpkgs>: set NIXPKGS=/path/to/nixpkgs" >&2; exit 2; }
export NIX_PATH="nixpkgs=$NIXPKGS"

RUN_POWER=1
[ "${1:-}" = "--no-poweroff" ] && RUN_POWER=0

echo "=== 1. build eMMC toplevel ==="
TOP="$(nix-build '<nixpkgs/nixos>' -I nixos-config="$PWD/sd-image-emmc.nix" \
        -A config.system.build.toplevel --no-out-link)"
echo "toplevel: $TOP"

echo "=== 2. build registration + tooling store paths ==="
# closureInfo refuses to run standalone here, but `nix-store --dump-db` over the
# closure produces the exact registration format register-nix-paths expects.
nix-store --dump-db $(nix-store -qR "$TOP") > /tmp/opencode/emmc-registration
REG_FILE=/tmp/opencode/emmc-registration
F2FS_TOOLS="$(nix-build '<nixpkgs>' -A f2fs-tools --no-out-link)"
DOSFSTOOLS="$(nix-build '<nixpkgs>' -A dosfstools --no-out-link)"
echo "registration: $REG_FILE  f2fs-tools: $F2FS_TOOLS  dosfstools: $DOSFSTOOLS"

echo "=== 3. sanity: board reachable? ==="
ssh -o ConnectTimeout=8 "$BOARD" "true"

echo "=== 4. push closure to board (~2 GiB over LAN) ==="
if ssh "$BOARD" "test -d $TOP" 2>/dev/null; then
  echo "closure already present on board — skipping push"
elif nix copy --to "ssh://$BOARD" "$TOP" "$F2FS_TOOLS" "$DOSFSTOOLS" 2>/tmp/opencode/nixcopy.log; then
  echo "pushed via nix copy"
else
  echo "nix copy rejected (untrusted) — falling back to nix-store export | sudo import"
  nix-store --export $(nix-store -qR "$TOP") "$F2FS_TOOLS" "$DOSFSTOOLS" | gzip | \
    ssh "$BOARD" "gunzip | sudo nix-store --import" 2>/dev/null
fi

echo "=== 5. push registration + board script ==="
ssh "$BOARD" "mkdir -p /tmp/emmc-transfer"
scp "$REG_FILE" "$BOARD:/tmp/emmc-transfer/nix-path-registration"
scp ./emmc-transfer-board.sh "$BOARD:/tmp/emmc-transfer/"

echo "=== 6. run transfer on board (wipes eMMC!) ==="
ssh "$BOARD" \
  "sudo env TOP=$TOP REG=/tmp/emmc-transfer/nix-path-registration \
   F2FS_TOOLS=$F2FS_TOOLS DOSFSTOOLS=$DOSFSTOOLS \
   CONFIRM_WIPE=YES-WIPE-EMMC RUN_POWER=$RUN_POWER \
   bash /tmp/emmc-transfer/emmc-transfer-board.sh"

echo "=== done. remove the SD card and boot from eMMC. ==="
echo "first eMMC boot: grow-emmc-root expands the f2fs filesystem to fill the device."
