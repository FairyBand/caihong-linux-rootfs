# Caihong Linux rootfs

English | [简体中文](README.zh-CN.md)

This repository builds an Arch Linux ARM userspace, matching mainline Linux
kernel, and Android boot images for the OnePlus Pad Pro (`caihong`). It is a
development release for this device; review the status table before installing.

## Device status

| Area | Status | Notes |
| --- | --- | --- |
| Display and GPU | Mostly working | The internal 3000×2120 display, Adreno GPU and brightness control work. Occasional small panel artifacts remain. |
| Touch and pen | Working | 10-point touch, hover, pressure, drawing, suspend/resume, magnetic pen charging and clean first-time pairing have been tested. |
| Pogo keyboard | Mostly working | Keyboard, touchpad and function-key mapping work. A key press can briefly pause the touchpad. |
| Wi-Fi | Mostly working | Client mode, factory MAC address and concurrent STA/AP mode work. Resume can be slow; the current BDF is a compatible vendor entry rather than a Caihong-specific calibration. |
| Bluetooth | Working | Scanning, pairing, BLE, HID and pen battery reporting work. |
| Cameras and flash | Mostly working | Front and rear cameras, autofocus, software ISP, calibration, torch and synchronized single flash work. The vendor hardware ISP and complete vendor tuning are unavailable. |
| Sensors and hall switch | Working | Accelerometer, gyroscope, ambient light, automatic brightness and cover hall switch work. |
| Audio | Working | Microphones and stereo speakers work. Speaker volume is lower than stock Android; Dolby and the complete stock tuning are not included. |
| USB and external display | Working | USB host/device controllers and DP Alt Mode work. |
| CPU and suspend | Working | CPU frequency scaling and suspend/resume work. The 3.3024 GHz boost is disabled by default. |
| Battery and fast charging | Mostly working | Battery reporting and tested PPS/VOOC charging work. Other charging protocols are not yet supported. |
| Storage | Working | Storage works; MCQ queues and the complete frequency table are not yet configured. |

## Release contents

- `caihong-boot-linux-<kernel-release>.img`: dual-boot image using the `linux`
  root partition.
- `caihong-boot-userdata-<kernel-release>.img`: single-system image using the
  `userdata` root partition.
- `caihong-rootfs-<kernel-release>.ext4.sparse.img`: Android sparse ext4 rootfs
  image that fastboot can flash directly. Images at or above 2 GiB are
  published as ordered `.part-00`, `.part-01`, … files.
- `linux-caihong-<version>-1-aarch64.pkg.tar.zst`: pacman package containing
  both direct-root boot images and the matching kernel modules.

The Release description records the SHA-256 digests, complete reconstructed
rootfs image digest, logical filesystem size and resolved source revisions. No
ZIP archive is used for installable assets.

## Installation

Follow these steps exactly. Repartitioning or flashing the wrong target can
erase Android and other device data.

### Prerequisites

- The bootloader is unlocked.
- `adb` and `fastboot` are installed on the host computer.
- Important Android and internal-storage data has been backed up.
- The boot image and rootfs image come from the same release.
- A dual-boot installation has a GPT partition named `linux`. If it already
  exists, skip the partition-creation step below.

### Prepare the files

Download one boot image and all rootfs image parts from the Release:

- Dual boot uses `caihong-boot-linux-<kernel-release>.img`.
- Single system uses `caihong-boot-userdata-<kernel-release>.img`.
- Both layouts use the same
  `caihong-rootfs-<kernel-release>.ext4.sparse.img`.

Compare every downloaded file with the SHA-256 values in the Release
description. The rootfs parts are not individually flashable. Reconstruct the
complete sparse image in part-number order, then compare its SHA-256 with the
complete-image digest in the Release description:

```sh
sha256sum caihong-boot-*.img caihong-rootfs-*.ext4.sparse.img.part-*
cat caihong-rootfs-*.ext4.sparse.img.part-* \
  > caihong-rootfs.ext4.sparse.img
sha256sum caihong-rootfs.ext4.sparse.img
```

If the Release contains one unsplit `.ext4.sparse.img`, use it directly and
skip the `cat` command.

### Dual boot

#### 1. Create or verify the Linux partition

Skip this step when `linux` already exists. Otherwise, boot a recovery that can
run `parted`. Use the recovery's copy, or push a compatible static binary:

```sh
adb reboot recovery
adb push /path/to/parted /tmp/parted
adb shell
chmod +x /tmp/parted
/tmp/parted /dev/block/sda
```

At the `parted` prompt, inspect the real layout first:

```text
unit GB
print
```

The exact partition number and boundaries vary with device capacity and the
existing layout. Keep the original `userdata` start unchanged, choose a split
point that leaves enough space for both systems, and ensure `linux` is larger
than the rootfs logical size recorded in the Release. Replace every value in
angle brackets before running these destructive commands:

```text
rm <userdata-number>
mkpart userdata ext4 <original-userdata-start> <linux-start>
mkpart linux ext4 <linux-start> 100%
print
quit
```

Confirm that the new partition names are exactly `userdata` and `linux`, then
return to the bootloader:

```sh
exit
adb reboot bootloader
```

#### 2. Flash the images

Choose the Linux slot explicitly. The following example uses slot B; use A
instead when that is the slot reserved for Linux:

```sh
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
ROOTFS=caihong-rootfs.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash linux "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

Erase only the DTBO belonging to the selected Linux slot. The Caihong DTB is
already inside the boot image; keep the Android slot's DTBO intact.

### Single system

This overwrites `userdata` and deletes Android user data. It does not require a
separate `linux` partition:

```sh
adb reboot bootloader
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-userdata-<kernel-release>.img
ROOTFS=caihong-rootfs.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash userdata "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

### First boot

The image contains an ext4 filesystem labeled `linux`. On the first successful
boot, `caihong-grow-rootfs.service` expands it to fill `linux` or `userdata`,
and `caihong-mark-boot-successful.service` marks the actual running slot
successful. No manual `resize2fs` command is required.

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

On an AArch64 host, install native GCC, Python 3, bsdtar, zstd, kmod,
alsa-utils, e2fsprogs and Android sparse-image tools (`img2simg`). On other
architectures, also install an AArch64 cross compiler and QEMU user emulation.
The scripts select the native or cross toolchain automatically:

```sh
scripts/checkout-dependencies.sh
scripts/build-kernel-release.sh
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=ext4 SPARSE_IMAGE=1 \
  scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).ext4.sparse.img"
```

GitHub Actions performs native AArch64 builds and persists ccache between
runs. Every Release description records the resolved component commits.

## Licensing

Project-authored build scripts and utilities are licensed under GPL-2.0-only
unless a file states another SPDX license. Camera tuning data keeps its stated
CC0 license. Bundled device firmware remains subject to its vendor terms.
