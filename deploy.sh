#!/usr/bin/env bash
# deploy.sh — build the current configuration and activate it on the board
# over ssh. Works for both the SD system and the eMMC system.
#
# Usage:
#   ./deploy.sh           # deploy the eMMC configuration (default)
#   ./deploy.sh sd        # deploy the SD configuration
#   ./deploy.sh --dry-run # build + push only, no switch
#
# Requires: git-tracked files (flakes), ssh key auth to the board, and on the
# board: security.sudo.wheelNeedsPassword = false + your key in
# configuration.nix (see the commented block there).
set -euo pipefail

cd "$(dirname "$0")"
BOARD="${DEPLOY_BOARD:-admin@kickpi-k2b.lan}"   # override with DEPLOY_BOARD=user@host

TARGET="emmc"
DRY=""
for arg in "$@"; do
  case "$arg" in
    sd) TARGET="sd" ;;
    emmc) TARGET="emmc" ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

case "$TARGET" in
  emmc) ATTR=".#nixosConfigurations.kickpi-k2b-emmc.config.system.build.toplevel" ;;
  sd)   ATTR=".#nixosConfigurations.kickpi-k2b-sd.config.system.build.toplevel" ;;
esac

echo "=== building toplevel ($TARGET) ==="
TOP="$(nix build "$ATTR" --no-link --print-out-paths)"
echo "toplevel: $TOP"

echo "=== pushing closure to board ==="
# Fast path: the board trusts @wheel (uncomment nix.settings.trusted-users in
# configuration.nix). Fallback: root import over ssh, always works.
if ! nix copy --to "ssh://$BOARD" "$TOP" 2>/tmp/deploy-nixcopy.log; then
  echo "nix copy rejected (target not trusting this host) — using root import fallback"
  nix-store --export $(nix-store -qR "$TOP") | gzip | \
    ssh "$BOARD" "gunzip | sudo nix-store --import" 2>/dev/null
fi

if [ -n "$DRY" ]; then
  echo "=== dry run: pushed, not switched. To switch manually: ==="
  echo "  ssh $BOARD \"sudo $TOP/bin/switch-to-configuration switch\""
  exit 0
fi

echo "=== switching ==="
ssh "$BOARD" "sudo $TOP/bin/switch-to-configuration switch"
echo "=== done — $TARGET system updated. ==="
