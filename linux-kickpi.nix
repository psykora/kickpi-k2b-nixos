# Lean kernel for KickPi K2B v2.2 (Allwinner H618) + Maxio MAE0621A ethernet PHY.
#
# k2b-minimal.config is a defconfig-style fragment: nixpkgs' linuxManualConfig
# links it as .config and runs `make oldconfig`, so every symbol NOT listed
# takes its Kconfig default. That gives a small, fast-building kernel
# (minutes instead of hours) while keeping crypto, WireGuard, serial, I2C,
# USB-serial dongle support and full nftables/xtables for podman.
#
# What got cut (see fragment): DRM/GPU, sound, media/IR, wireless/BT, staging,
# ftrace/debug-info, EFI/ACPI/PCI, CMA, KASLR.
{ pkgs ? import <nixpkgs> { } }:

pkgs.linuxManualConfig {
  version = "6.18.63";
  src = pkgs.linux_6_18.src;
  configfile = ./k2b-minimal.config;
  kernelPatches = [
    {
      name = "maxio-mae0621a-phy";
      patch = ./patches/maxio-mae0621a-phy-driver-v6.18.patch;
    }
  ];
  # Board DTBs come from ./dtbs via hardware.deviceTree.dtbSource,
  # so skip building the kernel's whole arm64 dtb set.
  buildDTBs = false;
}
