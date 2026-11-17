# Builds an f2fs image containing a populated /nix/store with the closure
# of store paths passed in the storePaths parameter, in addition to the
# contents of a directory that can be populated with commands. The
# generated image is sized to only fit its contents, with the expectation
# that a script resizes the filesystem at boot time.
# Modeled after nixpkgs' nixos/lib/make-ext4-fs.nix / make-btrfs-fs.nix —
# used as `sdImage.rootFilesystemCreator` for the KickPi K2B eMMC image.
{
  pkgs,
  lib,
  # List of derivations to be included
  storePaths,
  # Whether or not to compress the resulting image with zstd
  compressImage ? false,
  zstd,
  # Shell commands to populate the ./files directory.
  # All files in that directory are copied to the root of the FS.
  populateImageCommands ? "",
  volumeLabel,
  uuid ? "44444444-4444-4444-8888-888888888888",
  f2fs-tools,
  libfaketime,
  fakeroot,
}:

let
  sdClosureInfo = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "f2fs-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs =
    [
      f2fs-tools
      libfaketime
      fakeroot
    ]
    ++ lib.optional compressImage zstd;

  buildCommand = ''
    ${if compressImage then "img=temp.img" else "img=$out"}

    set -x
    (
        mkdir -p ./files
        ${populateImageCommands}
    )

    mkdir -p ./rootImage/nix/store

    xargs -I % cp -a --reflink=auto % -t ./rootImage/nix/store/ < ${sdClosureInfo}/store-paths
    (
      GLOBIGNORE=".:.."
      shopt -u dotglob

      for f in ./files/*; do
          cp -a --reflink=auto -t ./rootImage/ "$f"
      done
    )

    # Also include a manifest of the closures in a format suitable for nix-store --load-db
    cp ${sdClosureInfo}/registration ./rootImage/nix-path-registration

    # Crude approximation of the target image size, rounded up to the nearest
    # MiB, plus 25% headroom for f2fs metadata + overprovision.
    numInodes=$(find ./rootImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./rootImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * $numInodes + 4096 * $numDataBlocks))
    bytes=$(( bytes + bytes / 4 ))
    mebibyte=$(( 1024 * 1024 ))
    if (( bytes % mebibyte )); then
      bytes=$(( ( bytes / mebibyte + 1) * mebibyte ))
    fi
    echo "Creating an F2FS image of $bytes bytes (numInodes=$numInodes, numDataBlocks=$numDataBlocks)"

    truncate -s $bytes $img

    faketime -f "1970-01-01 00:00:01" fakeroot mkfs.f2fs -f -t 0 \
      -l ${volumeLabel} -U ${uuid} \
      -O extra_attr,inode_checksum,sb_checksum,compression \
      $img

    if ! fsck.f2fs -f $img; then
      echo "--- 'fsck.f2fs' failed for F2FS image ---"
      return 1
    fi

    if [ ${toString compressImage} ]; then
      echo "Compressing image"
      zstd -v --no-progress ./$img -o $out
    fi
  '';
}
