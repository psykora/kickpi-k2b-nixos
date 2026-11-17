# KickPi K2B — moving the system to the internal eMMC (f2fs)

The board runs from SD first; this documents two ways to get the same system
onto the internal 29 GiB eMMC, and how upgrades work afterwards.

Layout on eMMC (identical geometry conventions as the SD image):

    offset 8 KiB    Armbian U-Boot (SPL) — read by the BootROM
    p1  FAT  128M   /boot   label EMMCBOOT   extlinux.conf + kernel + initrd + DTBs
    p2  f2fs  rest  /       label NIXOS_EMMC flash-friendly root

Why FAT `/boot`: the U-Boot binary cannot read f2fs, so the boot files must
live on a filesystem it understands. The root is f2fs (flash-friendly, with
optional per-file compression — see below).

## Option A — transfer script (recommended, from the running SD system)

Requires the board to be booted from SD and reachable via ssh (key auth and
wheel sudo, enabled via the commented lines in `configuration.nix`). On the
build host:

    ./emmc-transfer.sh             # wipes the eMMC, transfers, powers off

What it does: builds the eMMC toplevel (`sd-image-emmc.nix`), pushes the
closure to the board, partitions the eMMC (identified by eMMC model string
`BJTD4R`, never by device number — those change every boot), writes U-Boot,
formats FAT + f2fs, copies the store, installs boot files, powers off.

Then remove the SD card and power on. On first boot `grow-emmc-root`
grows the root partition; f2fs auto-expands to fill it at mount time.

## Option B — dd the prebuilt eMMC image

    zstd -d result-emmc/sd-image/*.img.zst | sudo dd of=/dev/mmcblkX bs=4M conv=fsync status=progress

(Do this from another machine, or from the running SD system — never from a
system booted off the target device. Identify the eMMC by size/model, not by
device name.) Same first-boot behavior as Option A.

## Upgrades (after eMMC is running)

From the build host:

    ./deploy.sh                    # build + push + switch (eMMC config)
    # or, on a machine with nixos-rebuild:
    nixos-rebuild switch --flake .#kickpi-k2b-emmc --target-host admin@kickpi-k2b.lan
    ./deploy.sh sd                 # if a system on an SD card should be updated

Under the hood: `nix copy` the closure (the board trusts `@wheel`), then
`switch-to-configuration switch`. Kernel/initrd updates are copied to
`/boot` (FAT) by the activation; the previous generation stays selectable
in the U-Boot extlinux menu for rollback.

## Optional: f2fs compression for /nix/store

The filesystem was created with the `compression` feature and the kernel has
`F2FS_FS_COMPRESSION`. To compress store paths (they are marked
compressible only on request):

    sudo mount -o remount,compress_algorithm=zstd:6 /
    # make it permanent: add to fileSystems."/".options in sd-image-emmc.nix
    # then mark existing files: sudo chattr -R +c /nix/store   (optional, slow)

## Notes

- The SD card that did the transfer remains a fully working fallback: reinsert
  and boot to rescue.
- Device numbers (`mmcblk0/1/2`) change between boots — always identify disks
  by label (`NIXOS_EMMC`, `EMCBOOT`) or by eMMC model (`BJTD4R`).
- `grow-emmc-root` only acts while `/nix-path-registration` exists (first
  boot of a fresh flash); later boots skip it.
