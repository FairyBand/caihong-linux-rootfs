# Caihong Linux rootfs

English | [简体中文](README.zh-CN.md)

This repository builds an Arch Linux ARM userspace, matching mainline Linux
kernel, and Android boot images for the OnePlus Pad Pro (`caihong`). It is a
development release for this device; review the status table before installing.

The boot images use Android boot image v2 and contain only the Linux `Image`
and the Caihong DTB. There is no ramdisk. The dual-boot image mounts the GPT
partition named `linux` directly:

```text
root=PARTLABEL=linux rootfstype=ext4 rootwait rw
```

The single-system image mounts `PARTLABEL=userdata` instead. All loadable
drivers, firmware and device-specific userspace are stored in the rootfs.

## Device status

| Area | Status | Notes |
| --- | --- | --- |
| Display, GPU and DP | Mostly working | Internal 3000×2120 display, Adreno GPU, brightness and DP Alt Mode work. Occasional small panel artifacts remain. |
| Touch and pen | Working | 10-point touch, hover, pressure, drawing, suspend/resume and magnetic pen charging have been tested. Fresh first-time pen pairing needs more regression coverage. |
| Pogo keyboard | Mostly working | Keyboard, touchpad and function-key mapping work. A key press can briefly pause the touchpad. |
| Wi-Fi | Mostly working | Client mode, factory MAC address and concurrent STA/AP mode work. Resume can be slow; the current BDF is a compatible vendor entry rather than a Caihong-specific calibration. |
| Bluetooth | Working | Scanning, pairing, BLE, HID and pen battery reporting work. BNEP/PAN is not enabled in the current kernel configuration. |
| Cameras and flash | Mostly working | Front and rear cameras, autofocus, software ISP, calibration, torch and synchronized single flash work. The vendor hardware ISP and complete vendor tuning are unavailable. |
| Sensors and hall switch | Working | Accelerometer, gyroscope, ambient light, automatic brightness and cover hall switch work. The tablet has no known pressure or proximity sensor. |
| Audio | Working | Microphones and stereo speakers work. Speaker volume is lower than stock Android; Dolby and the complete stock tuning are not included. |
| USB and external display | Working | USB host/device controllers and DP Alt Mode work. No USB gadget function is enabled by default. |
| CPU and suspend | Working | CPU frequency scaling and suspend/resume work. The 3.3024 GHz boost is disabled by default; Wi-Fi resume can be slow. |
| Battery and fast charging | Mostly working | Battery reporting and tested PPS/VOOC charging work. More temperature ranges and a complete low-to-full charging cycle still need coverage. |
| Storage | Needs maintenance | Storage works, but the current development filesystem has reported ext4 metadata errors and should be checked offline with `e2fsck`. |

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

## Installation

An unlocked bootloader and a Linux environment that can access the target
partition are required. Back up any data on the selected partition first.

Choose one layout:

- **Dual boot:** use an existing GPT partition whose `PARTLABEL` is `linux`,
  and use the `caihong-boot-linux-*.img` image.
- **Single system:** use the existing `userdata` partition and the
  `caihong-boot-userdata-*.img` image. Formatting this partition deletes
  Android user data.

Download the selected boot image, rootfs files, `SHA256SUMS`, and
`release-manifest.json`. Verify every downloaded asset that is present:

```sh
sha256sum --ignore-missing -c SHA256SUMS
```

If the rootfs is split, reconstruct it in part-number order:

```sh
cat caihong-rootfs-*.tar.zst.part-* > caihong-rootfs.tar.zst
```

From Linux or a suitable recovery environment, identify the target by its GPT
partition name. Set `ROOTFS` to the downloaded archive, or to the reconstructed
`caihong-rootfs.tar.zst` shown above. Replace `/dev/TARGET` only after checking
the output:

```sh
lsblk -o PATH,SIZE,FSTYPE,LABEL,PARTLABEL
TARGET=/dev/TARGET
ROOTFS=caihong-rootfs.tar.zst

sudo umount "$TARGET" 2>/dev/null || true
sudo mkfs.ext4 -F -L linux "$TARGET"
sudo mkdir -p /mnt/caihong-rootfs
sudo mount "$TARGET" /mnt/caihong-rootfs
sudo bsdtar --numeric-owner --acls --xattrs -xpf "$ROOTFS" \
  -C /mnt/caihong-rootfs
sudo sync
sudo umount /mnt/caihong-rootfs
```

The filesystem label `linux` is used by the first-boot grow service; the boot
image selects the root filesystem by the GPT `PARTLABEL` described above.

Enter fastboot mode and inspect the current slot. Select the slot that will
contain Linux explicitly; do not overwrite the slot that you intend to keep
for Android:

```sh
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

Use the `userdata` boot image in `BOOT` for a single-system installation. On a
successful first boot, the system records and marks the actual running slot as
successful.

## Default accounts

| User | Password | Purpose |
| --- | --- | --- |
| `alarm` | `alarm` | Plasma desktop user; member of `wheel` and allowed to use `sudo` with its password. |
| `root` | `root` | System administrator account. |

When logged in as `alarm`, change both passwords immediately after the first
login:

```sh
passwd
sudo passwd root
```

## Caihong userspace utilities

The following board-specific tools are preinstalled under `/usr/local`.
Commands that change hardware or boot state require root privileges.

| Utility | Purpose and example |
| --- | --- |
| `caihong-slot` | Inspect or switch A/B slots: `sudo caihong-slot status`, `sudo caihong-slot android --reboot`. |
| `caihong-flashlight` | Control the rear torch: `sudo caihong-flashlight on 40`, `status`, or `off`. |
| `caihong-hotspot` | Run the concurrent Wi-Fi AP without disconnecting the STA: `sudo caihong-hotspot start`; also provides `status`, `stop`, and `regulatory {show\|set CODE\|reset}`. Configure it in `/etc/caihong-hotspot.conf`. |
| `caihong-hardware-mac` | Reads the factory WLAN and Bluetooth addresses from the redundant device NVRAM and applies them during boot. |
| `caihong-bluetooth-autostart` | Powers on the configured Bluetooth controller during boot. |
| `caihong-pen-pair` | Pairs a pen address obtained from a validated CPS8601 magnetic-attach event. Normally run by its systemd timer. |
| `caihong-pen-charge` | Performs a bounded CPS8601 charging/attach observation. Normally run by its systemd timer. |
| `caihong-pen-autoconnect` | Restores the paired pen connection and touchscreen pen scan mode. Normally run by its systemd timer. |
| `caihong-mark-boot-successful` | Records the actual booted slot and marks only that slot successful. Runs automatically at boot. |
| `caihong-fix-kwin-brightness` | Installs the stock-derived ambient-light curve into the `alarm` user's KWin display configuration. |
| `caihong-clean-pogo-kde` | Removes KDE keyboard-backlight actions that do not apply to the Pogo keyboard. |
| `caihong-nvram-mac` | Internal `/usr/local/libexec` reader used by `caihong-hardware-mac`. |
| `caihong-switch-to-android.desktop` | Plasma application-menu entry that runs `caihong-slot android --reboot` through polkit. |

The rootfs also includes the Caihong SSC service, custom libcamera stack,
Plasma Camera integration, firmware, audio topology and matching kernel
modules.

## Kernel updates

Upgrade the kernel, DTB and modules from a release package with:

```sh
sudo pacman -U ./linux-caihong-*-aarch64.pkg.tar.zst
```

The package reads the slot recorded during the current boot, selects the image
matching the actual `linux` or `userdata` root partition, writes only that
running slot, and verifies the written bytes. It does not alter the A/B active,
bootable, or successful flags.

## Building locally

On an AArch64 host, install native GCC, Python 3, bsdtar, zstd, kmod and
alsa-utils. On other architectures, also install an AArch64 cross compiler and
QEMU user emulation. The scripts select the native or cross toolchain
automatically:

```sh
scripts/checkout-dependencies.sh
scripts/build-kernel-release.sh
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=tar scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).tar.zst"
```

GitHub Actions performs native AArch64 builds and persists ccache between
runs. Every release records the resolved component commits in
`release-manifest.json`.

## Licensing

Project-authored build scripts and utilities are licensed under GPL-2.0-only
unless a file states another SPDX license. Camera tuning data keeps its stated
CC0 license. Bundled device firmware remains subject to its vendor terms.
