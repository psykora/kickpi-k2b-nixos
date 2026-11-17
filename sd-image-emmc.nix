# sd-image-emmc.nix — KickPi K2B image destined for the internal eMMC
#
# Layout (same disk geometry conventions as the SD image, different labels/UUIDs
# so SD and eMMC never collide when both are attached):
#   gap 8 KiB      : Armbian U-Boot (SPL), written by populateFirmwareCommands
#   p1 FAT 128 MiB : /boot — extlinux.conf + kernel + initrd + DTBs
#                    (U-Boot reads vfat; it CANNOT read f2fs)
#   p2 f2fs        : /    — flash-friendly root (opt-in zstd compression for
#                    the Nix store via the compress_algorithm mount option)
#
# Build:
#   nix-build '<nixpkgs/nixos>' -I nixos-config=$PWD/sd-image-emmc.nix \
#     -A config.system.build.sdImage -o result-emmc
#
# Transfer from a running system: see EMMC.md.
{ config, lib, pkgs, ... }:

{
  imports = [
    # brings in: platform bits (U-Boot @ 8 KiB, no firmware, serial console),
    # ./configuration.nix (lean kernel, podman, ssh, remote-upgrade keys)
    ./sd-image.nix
  ];

  # Distinct labels/IDs so the eMMC never collides with a plugged-in SD card
  image.baseName = lib.mkForce "nixos-emmc-k2b";
  sdImage.firmwarePartitionID = "0x66666666";
  sdImage.firmwarePartitionName = "EMMCBOOT";
  sdImage.firmwareSize = 128; # kernel Image (15M) + initrd (~25M) + DTBs + slack
  sdImage.rootVolumeLabel = "NIXOS_EMMC";
  sdImage.rootPartitionUUID = "33333333-3333-3333-8888-888888888888";

  # f2fs root (upstream only ships ext4/btrfs creators; ours lives beside this file)
  sdImage.rootFilesystemCreator = ./make-f2fs-fs.nix;

  # The boot files live on FAT p1, not on the (f2fs, unreadable by U-Boot) root
  sdImage.populateRootCommands = lib.mkForce "";
  sdImage.populateFirmwareCommands = lib.mkForce ''
    # Armbian U-Boot for KickPi K2B: SPL+U-Boot at 8 KiB offset
    dd if=${./uboot-bin/u-boot-sunxi-with-spl.bin} of=$img bs=1024 seek=8 conv=notrunc
    # extlinux.conf + kernel + initrd + DTBs onto the FAT partition
    ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
      -c ${config.system.build.toplevel} -d ./firmware
  '';

  fileSystems = lib.mkForce {
    "/boot" = {
      device = "/dev/disk/by-label/${config.sdImage.firmwarePartitionName}";
      fsType = "vfat";
      options = [ "nofail" ];
    };
    "/" = {
      device = "/dev/disk/by-label/${config.sdImage.rootVolumeLabel}";
      fsType = "f2fs";
      # Flash-friendly root; opt-in zstd compression (files are marked
      # compressible with `chattr +c`). Keep as an easy toggle:
      # options = [ "compress_algorithm=zstd:6" ];
    };
  };

  # f2fs userland (mkfs/fsck/resize) on the target system
  boot.supportedFilesystems = [ "f2fs" ];

  # The upstream expand-root-partition service hardcodes resize2fs (ext4-only);
  # replace with the f2fs equivalent. Gated on /nix-path-registration so it
  # runs once, on first boot of a freshly flashed device.
  sdImage.expandOnBoot = lib.mkForce false;
  systemd.services.grow-emmc-root = {
    description = "Grow the eMMC root partition and f2fs filesystem to fill the device";
    wantedBy = [ "sysinit.target" ];
    before = [ "sysinit.target" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    after = [ "local-fs.target" ];
    restartIfChanged = false;
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = config.sdImage.nixPathRegistrationFile;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      util-linux
      gawk
    ];
    script = ''
      # Figure out device names for the boot device and root filesystem.
      rootPart=$(${lib.getExe' pkgs.util-linux "findmnt"} -n -o SOURCE /)
      bootDevice=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo PKNAME $rootPart)
      partNum=$(${lib.getExe' pkgs.util-linux "lsblk"} -npo MAJ:MIN $rootPart | ${lib.getExe pkgs.gawk} -F: '{print $2}')

      # Grow the root partition. The kernel re-read may return busy on a mounted
      # root; f2fs auto-expands to the (grown) partition size at next mount, so
      # a failed re-read here is not fatal.
      echo ",+," | ${lib.getExe' pkgs.util-linux "sfdisk"} -N$partNum --no-reread $bootDevice || true
      ${lib.getExe' pkgs.util-linux "blockdev"} --rereadpt $bootDevice || true
      ${lib.getExe' pkgs.util-linux "partx"} -u $rootPart 2>/dev/null || true
      # No resize.f2fs needed: f2fs auto-expands on mount when the underlying
      # partition is larger than the filesystem.
    '';
  };
}
