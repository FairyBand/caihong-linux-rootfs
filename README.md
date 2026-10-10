# Caihong Linux rootfs

This repository builds the Arch Linux ARM userspace and matching mainline Linux
boot image for the OnePlus Pad Pro (`caihong`).

The first public release is pending final direct-root validation on hardware.

The Android boot v2 image contains only the Linux `Image` and the Caihong DTB.
Its external ramdisk size is zero. Linux mounts the existing GPT partition
named `linux` directly with:

```
root=PARTLABEL=linux rootfstype=ext4 rootwait rw
```

All loadable drivers, firmware and device userspace live in the rootfs. The
build follows the stable component branches in `dependencies.env`, records
the commits resolved for every release, and rejects a rootfs or module tree
whose kernel release does not match the boot image.

## Release contents

- `caihong-boot-<kernel-release>.img`: unsigned Android boot v2 image.
- `caihong-rootfs-<kernel-release>.tar.zst`: rootfs archive. Archives at or
  above 2 GiB are published as ordered `.part-00`, `.part-01`, … files.
- `release-manifest.json`: source revisions, sizes and SHA-256 digests.
- `SHA256SUMS`: digest for every downloadable asset.

Reconstruct a split rootfs before extraction:

```sh
cat caihong-rootfs-*.tar.zst.part-* > caihong-rootfs.tar.zst
```

The target GPT partition must be named `linux` and formatted as ext4. Extract
the archive as root so numeric ownership, ACLs and extended attributes are
preserved. Flash the boot image only to the selected boot slot; the project
uses `boot_b` during development and leaves `boot_a` untouched.

## Building locally

Install an AArch64 cross compiler, `mkbootimg`, QEMU user emulation, bsdtar,
zstd, kmod and alsa-utils. Then run:

```sh
scripts/checkout-dependencies.sh
JOBS=31 scripts/build-kernel-release.sh
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=tar scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).tar.zst"
```

GitHub Actions performs the same build for `v*` tags and manual release runs.
`dependencies.env` follows the stable component branches. Each release records
the exact commits resolved during that build in `release-manifest.json`.

## Licensing

Project-authored build scripts and utilities are licensed under GPL-2.0-only
unless a file states another SPDX license. Camera tuning data keeps its stated
CC0 license. Bundled device firmware remains subject to its vendor terms.
