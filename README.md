# Caihong Linux rootfs

This repository builds the Arch Linux ARM userspace and matching mainline Linux
boot image for the OnePlus Pad Pro (`caihong`).

The first public release is pending final direct-root validation on hardware.

Both Android boot v2 images contain only the Linux `Image` and the Caihong DTB.
Their external ramdisk size is zero. The normal dual-boot image mounts the
existing GPT partition named `linux` directly with:

```
root=PARTLABEL=linux rootfstype=ext4 rootwait rw
```

The single-system image instead uses `root=PARTLABEL=userdata`. This variant
is intended for installations that replace Android user data with the Linux
root filesystem.

All loadable drivers, firmware and device userspace live in the rootfs. The
build follows the stable component branches in `dependencies.env`, records
the commits resolved for every release, and rejects a rootfs or module tree
whose kernel release does not match the boot image.

## Release contents

- `caihong-boot-linux-<kernel-release>.img`: dual-boot image using the `linux`
  root partition.
- `caihong-boot-userdata-<kernel-release>.img`: single-system image using the
  `userdata` root partition.
- `caihong-rootfs-<kernel-release>.tar.zst`: rootfs archive. Archives at or
  above 2 GiB are published as ordered `.part-00`, `.part-01`, … files.
- `linux-caihong-<version>-1-aarch64.pkg.tar.zst`: pacman package containing
  both direct-root boot images and the matching kernel modules.
- `release-manifest.json`: source revisions, sizes and SHA-256 digests.
- `SHA256SUMS`: digest for every downloadable asset.

Reconstruct a split rootfs before extraction:

```sh
cat caihong-rootfs-*.tar.zst.part-* > caihong-rootfs.tar.zst
```

Format the root partition selected by the boot image as ext4 and extract the
archive as root so numeric ownership, ACLs and extended attributes are
preserved. Flash the matching boot image only to the selected boot slot; the
project uses `boot_b` during development and leaves `boot_a` untouched.

## Building locally

On an AArch64 host, install native GCC, Python 3, bsdtar, zstd, kmod and
alsa-utils. On other architectures, also install an AArch64 cross compiler and
QEMU user emulation. The build scripts select the native or cross toolchain
automatically, and the dependency checkout supplies AOSP `mkbootimg.py`. Then
run:

```sh
scripts/checkout-dependencies.sh
scripts/build-kernel-release.sh
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=tar scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).tar.zst"
```

GitHub Actions performs the same build for `v*` tags and manual release runs.
`dependencies.env` follows the stable component branches. Each release records
the exact commits resolved during that build in `release-manifest.json`.

On an installed Caihong system, upgrade the kernel and modules with:

```sh
sudo pacman -U linux-caihong-*-aarch64.pkg.tar.zst
```

The package reads the slot recorded during the current boot, selects the boot
image matching the actual `linux` or `userdata` root partition, writes only
that running slot, and verifies the written bytes. It does not change the A/B
active, bootable, or successful flags.

## Licensing

Project-authored build scripts and utilities are licensed under GPL-2.0-only
unless a file states another SPDX license. Camera tuning data keeps its stated
CC0 license. Bundled device firmware remains subject to its vendor terms.
