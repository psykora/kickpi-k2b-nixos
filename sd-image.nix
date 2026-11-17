# sd-image.nix — SD image for KickPi K2B v2.2 (Allwinner H618)
#
# Based on sd-image-aarch64.nix, but without the Raspberry Pi firmware files
# (bootcode.bin, bcm27xx DTBs, Pi u-boot.bin) that that module puts into the
# FAT partition — none of that applies to Allwinner boards. Instead:
#   * the Armbian U-Boot binary is written raw into the 8 MiB gap before the
#     first partition (sunxi convention: SPL at 8 KiB offset),
#   * extlinux.conf + kernel + DTBs land in /boot on the ext4 root partition
#     (via boot.loader.generic-extlinux-compatible), which U-Boot finds by
#     scanning partitions.
{ config, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
    "${modulesPath}/profiles/base.nix"
    ./configuration.nix
  ];

  # The upstream sd-image module sets hardware.enableAllHardware, which pulls
  # the full linux-firmware set (~1 GB of wifi/BT/GPU blobs) plus ~100 initrd
  # modules into the image. The K2B kernel has no wifi/BT/GPU drivers and the
  # board needs no firmware at all — drop all of it.
  hardware.enableAllHardware = lib.mkForce false;
  hardware.enableAllFirmware = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = lib.mkForce [ ];

  # H618 console is on the 16550-compatible UART (ttyS0)
  boot.kernelParams = [ "console=ttyS0,115200n8" ];
  boot.consoleLogLevel = 7;

  sdImage = {
    populateFirmwareCommands = ''
      # Armbian U-Boot for KickPi K2B: SPL+U-Boot at 8 KiB offset.
      # ($img is the whole SD image file; first partition starts at 8 MiB.)
      dd if=${./uboot-bin/u-boot-sunxi-with-spl.bin} of=$img bs=1024 seek=8 conv=notrunc
    '';

    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c ${config.system.build.toplevel} -d ./files/boot
    '';
  };
}
