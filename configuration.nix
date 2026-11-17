{ config, pkgs, lib, ... }:

{
  # Disable GRUB, which is for x86 systems
  boot.loader.grub.enable = false;

  # Enable the extlinux-compatible bootloader, which U-Boot understands
  boot.loader.generic-extlinux-compatible.enable = true;

  # Tell NixOS to use your local dtbs directory as the source
  hardware.deviceTree.dtbSource = ./dtbs;

  # Our kernel skips building the full arm64 dtb set (buildDTBs = false in
  # linux-kickpi.nix), and hardware.deviceTree.enable defaults to that flag —
  # so enable it explicitly here to keep the ./dtbs flow alive.
  hardware.deviceTree.enable = true;

  # CRITICAL: Explicitly set the Device Tree Blob for your board
  # The path is relative to the kernel's dtb directory
  hardware.deviceTree.name = "allwinner/sun50i-h618-kickpi-k2b.dtb";

  # Lean custom kernel: dwmac-sun8i + Maxio MAE0621A PHY patch are baked in
  # (see ./linux-kickpi.nix and ./k2b-minimal.config). No boot.kernelPatches here!
  boot.kernelPackages = pkgs.linuxPackagesFor (import ./linux-kickpi.nix { inherit pkgs; });

  # marked as broken right now
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # sd-image.nix imports profiles/all-hardware.nix, which lists ~100 storage
  # modules for the initrd. Our lean kernel builds everything needed as =y
  # (no modules), so tell the initrd builder to tolerate missing ones.
  boot.initrd.allowMissingModules = true;

  # Basic headless server configuration
  networking.hostName = "kickpi-k2b";
  networking.networkmanager.enable = true; # For easy ethernet management
  services.openssh.enable = true;          # Essential for headless access

  # Disable WiFi and Bluetooth since you don't need them
  networking.wireless.enable = lib.mkForce false;
  hardware.bluetooth.enable = false;

  # Podman for Home Assistant containers
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;                          # `docker` alias for podman
    defaultNetwork.settings.dns_enabled = true;   # aardvark-dns: container name resolution
  };

  # Remote upgrades from a build host (./deploy.sh) need wheel sudo without a
  # password and a trusted nix user. Both are disabled by default — this is a
  # public repository. Uncomment and add your key if you want them.
  # security.sudo.wheelNeedsPassword = false;
  # nix.settings.trusted-users = [ "root" "@wheel" ];

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme"; # change this!
    # openssh.authorizedKeys.keys = [
    #   "ssh-ed25519 AAAA... your-key-here"
    # ];
  };

  system.stateVersion = "26.05"; # Use the current NixOS version
}
