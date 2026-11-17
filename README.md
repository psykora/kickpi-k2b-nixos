# NixOS on KickPi K2B — lean headless server (H618 + Maxio PHY + podman)

A minimal, fast-building [NixOS](https://nixos.org) setup for the **KickPi K2B
v2.2** (Allwinner H618, 4 GB DDR3, Maxio MAE0621A ethernet PHY), targeting a
headless Home-Assistant-style server: ethernet, ssh, podman, no
HDMI/audio/WiFi/BT.

The stock NixOS kernel config builds thousands of unneeded drivers and takes
hours on this class of hardware. Here the kernel is a curated ~1300-line
config that builds in **~10 minutes on 8 arm64 cores** and produces a
**~400 MiB compressed SD image** (vs ~1.4 GB with defaults).

## What works

- Boot via Armbian U-Boot + extlinux (U-Boot is written into the image at the
  8 KiB sunxi offset — no manual `dd` step)
- Gigabit MAC (`dwmac-sun8i`) + **Maxio MAE0621A PHY driver** (out-of-tree
  patch, adjusted to kernel 6.18; MAC address auto-derived from the chip SID
  by U-Boot → stable DHCP leases)
- SD + eMMC (eMMC runs **f2fs** — see [EMMC.md](EMMC.md))
- USB host incl. serial adapters (CP210x/FTDI/CH341/PL2303 — Zigbee/Z-Wave
  sticks), USB storage
- Full nftables **+ xtables-compat firewall** (NixOS default firewall works)
- WireGuard, TUN, bridges/veth/overlay — podman runs rootless out of the box
  (cgroup v2, netavark + aardvark-dns)
- Full crypto stack incl. arm64 CE accelerators + Allwinner `sun8i-ce` engine
- Serial console `ttyS0` 115200 8n1; `/proc/config.gz` (kernel config embedded)

Deliberately **not** built (kernel-side): DRM/GPU, sound, media/IR,
wireless/BT, staging, ftrace/debug-info, EFI/ACPI/PCI, KASLR, CMA.

## Repo layout

| file | purpose |
|---|---|
| `flake.nix` + `flake.lock` | pinned entry point: `.#sd-image`, `.#emmc-image`, `.#nixosConfigurations.*` |
| `sd-image.nix` | SD image module: U-Boot @ 8 KiB, no Pi firmware cruft, no linux-firmware |
| `sd-image-emmc.nix` | eMMC image variant: FAT `/boot` + f2fs root (see [EMMC.md](EMMC.md)) |
| `configuration.nix` | system config: ssh, NetworkManager, podman, users |
| `linux-kickpi.nix` | kernel wrapper: `linuxManualConfig` + Maxio patch |
| `k2b-minimal.config` | the curated kernel config fragment (annotated; unlisted symbols keep Kconfig defaults) |
| `patches/maxio-mae0621a-phy-driver-v6.18.patch` | PHY driver (from the linux-sunxi community, adjusted to 6.18) |
| `dtbs/` | board DTBs taken from Armbian |
| `uboot-bin/` | Armbian `u-boot-sunxi-with-spl.bin` (vendored, written at offset 8 KiB) |
| `make-f2fs-fs.nix` | f2fs image creator for `sdImage.rootFilesystemCreator` |
| `emmc-transfer.sh` + `emmc-transfer-board.sh` | live SD→eMMC transfer (Armbian-install style) |
| `deploy.sh` | build + push + remote-switch helper |

## Quick start (SD card)

On any Linux machine with nix (aarch64 native is fastest; flakes enabled):

```sh
git add .                      # flakes only see tracked files
nix build .#sd-image           # -> result/sd-image/*.img.zst
zstd -d result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Boot with a serial console on `ttyS0` (115200 8n1) or just wait for ssh:
user `admin`, password `changeme` — **change it**, and add your ssh key in
`configuration.nix`.

First boot grows the root partition to fill the card (~2 min).

## Move to eMMC / upgrade

See [EMMC.md](EMMC.md). Short version: `./emmc-transfer.sh` (live transfer,
no second flash) or dd `result-emmc`. Afterwards everything ships over ssh:

```sh
./deploy.sh
# or, on a machine with nixos-rebuild:
nixos-rebuild switch --flake .#kickpi-k2b-emmc --target-host admin@kickpi-k2b.lan
```

Remote deploys need the commented `security.sudo.wheelNeedsPassword` /
`nix.settings.trusted-users` lines and your ssh key enabled in
`configuration.nix`. The previous generation stays bootable via the U-Boot
extlinux menu for rollback.

## Kernel config in one paragraph

`k2b-minimal.config` is a *fragment*, not a full `.config`: nixpkgs'
`linuxManualConfig` fills unlisted symbols with Kconfig defaults. The fragment
enables the H616 platform (clocks/pinctrl/DMA/RTC/thermal/cpufreq), MMC, the
Maxio-patched stmmac, USB host + serial dongles, full nftables **and**
xtables-compat (NixOS firewall + podman/netavark), systemd requirements
(cgroups v2, namespaces), ext4 + f2fs (+compression) + FAT/exFAT, WireGuard,
and the crypto stack; it disables DRM/GPU, sound, media, wireless, BT,
staging, ftrace/debug-info, EFI/ACPI/PCI, KASLR and CMA. `CONFIG_MODULES=y`
with zero modules built; everything the board needs is `=y`.

## Known limitations

- `BPF_LSM` is off (it would drag in kprobes/ftrace). The stock `lsm=` boot
  parameter mentions `bpf`; the kernel skips it silently. The bundled systemd
  is built without BTF and doesn't use it.
- U-Boot is a vendored Armbian binary; it is written into every image/transfer
  and never needs updating unless you swap it deliberately.
- `hardware.deviceTree.enable` must stay `true` (it defaults to
  `kernel.buildDTBs`, which we turn off because DTBs come from `./dtbs`).
- The eMMC image path is verified offline (partition table, FAT contents,
  f2fs superblock + fsck) and shares every component with the live-tested
  transfer path, but has not itself been dd'd and booted — if you do, treat
  the first boot as the test.
