# NixOS images for the KickPi K2B v2.2 (Allwinner H618, Maxio MAE0621A PHY).
#
# Build without git-tracked state issues: `git add .` first (flakes only see
# tracked files in git repos), then:
#
#   nix build .#sd-image     # SD card image  -> result/sd-image/*.img.zst
#   nix build .#emmc-image   # eMMC image     -> result-emmc/sd-image/*.img.zst
#
# Deploy to a running board:
#   nixos-rebuild switch --flake .#kickpi-k2b-emmc --target-host admin@kickpi-k2b.lan
#
# The nixpkgs revision is pinned in flake.lock.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      # private identity/deploy settings: imported when configuration-local.nix
      # exists (it is git-ignored; see .gitignore)
      localModule =
        if builtins.pathExists ./configuration-local.nix
        then [ ./configuration-local.nix ]
        else [ ];
    in
    {
      nixosConfigurations = {
        # Running systems (used by nixos-rebuild --flake for remote deploys)
        kickpi-k2b-sd = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./sd-image.nix ] ++ localModule;
        };
        kickpi-k2b-emmc = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ ./sd-image-emmc.nix ] ++ localModule;
        };
      };

      packages.${system} = {
        sd-image = self.nixosConfigurations.kickpi-k2b-sd.config.system.build.sdImage;
        emmc-image = self.nixosConfigurations.kickpi-k2b-emmc.config.system.build.sdImage;
        # handy for debugging config mismatches
        default = pkgs.linkFarm "kickpi-k2b-images" [
          { name = "sd-image"; path = self.packages.${system}.sd-image; }
          { name = "emmc-image"; path = self.packages.${system}.emmc-image; }
        ];
      };
    };
}
