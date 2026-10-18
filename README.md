# Caihong Fedora

English | [简体中文](README.zh-CN.md)

Fedora Workstation 44 (GNOME, AArch64) for the OnePlus Pad Pro (`caihong`).
This `fedora` branch builds the mainline-based Caihong kernel, Android boot
images and a Fedora rootfs whose device support comes from RPM packages in the
[`fairyband/caihong`](https://copr.fedorainfracloud.org/coprs/fairyband/caihong/)
Copr project.

This repository is a fork of
[Osilvfe/caihong-linux-rootfs](https://github.com/Osilvfe/caihong-linux-rootfs).
Its `main` branch follows upstream, which builds Arch Linux ARM and Armada
images. The Fedora branch drops those build paths and keeps only what Fedora
needs. It is a development port; read [TODO.md](TODO.md) before installing.

## Status

Open issues and finished work are tracked in [TODO.md](TODO.md). Verified on
Fedora so far:

- GNOME on the internal display with the Adreno 750 GPU (Mesa/Vulkan; vkmark
  needs a size divisible by 3, see TODO.md).
- Iris hardware video encoding and decoding: FFmpeg `h264_v4l2m2m` and
  `hevc_v4l2m2m`, plus OBS Studio recording and streaming through
  `obs-studio-plugin-v4l2m2m`.
- Wi-Fi, Bluetooth, the Pogo keyboard, audio, SSC sensors and the kernel A/B
  updater are packaged. Front and rear camera capture still produce black
  frames.

SELinux runs in `permissive` mode by default. Service policies are not
written yet; see
[docs/fedora44-gnome-migration-research.zh-CN.md](docs/fedora44-gnome-migration-research.zh-CN.md).

## Repository layout

| Path | Purpose |
| --- | --- |
| `scripts/checkout-dependencies.sh`, `dependencies.env` | Fetch the Caihong Linux tree and `mkbootimg` at the configured refs. |
| `scripts/build-kernel-release.sh` | Build the kernel with `packaging/kernel/caihong-fedora-selinux.config`, the modules, and both direct-root boot images. |
| `scripts/package-fedora-rootfs.sh` | Build the Fedora ext4 rootfs from the official Workstation raw image and the Copr packages. |
| `scripts/verify-fedora-rootfs.sh` | Check a built rootfs: distribution, Copr EVRs, SELinux and kernel payload. |
| `scripts/collect-caihong-diagnostics.sh` | Collect logs and hardware state from a running device. |
| `rootfs/caihong/` | Device integration overlay (udev, systemd units, board utilities, UCM2). The Copr packages install most of these files. |
| `firmware/`, `firmware-assets/` | Device firmware and SSC userspace payloads with SHA-256 lists. |
| `external/audioreach-topology/` | Source for the AudioReach topology in `firmware/`. |
| `.github/workflows/fedora-rootfs.yml` | Builds the kernel, boot images and rootfs on a native ARM64 runner. |

RPM specs live in
[FairyBand/caihong-fedora-rpms](https://github.com/FairyBand/caihong-fedora-rpms):
`caihong-device-support`, `caihong-firmware`, `caihong-audio`, `caihong-ssc`,
`caihong-qbootctl`, `caihong-kernel-updater`, `caihong-kernel-payload`, plus
rebuilds of `libcamera`, `plasma-camera` and `ffmpeg` and the
`obs-studio-plugin-v4l2m2m` plugin.

## Build artifacts

The `Build Fedora Caihong rootfs` workflow (run it from the Actions page)
uploads:

- `caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img`: flashable Android
  sparse ext4 rootfs labeled `linux`.
- `caihong-boot-linux-<kernel-release>.img`: boot image for the dual-boot
  `linux` partition.
- `caihong-boot-userdata-<kernel-release>.img`: boot image for a single
  system on `userdata`.
- `SHA256SUMS.fedora`, `SHA256SUMS.boot`, the boot image manifests and the
  kernel `config-<kernel-release>`.

Check every file against `SHA256SUMS.fedora` before flashing:

```sh
sha256sum -c SHA256SUMS.fedora
```

## Installation

Follow these steps exactly. Repartitioning or flashing the wrong target can
erase Android and other device data.

### Prerequisites

- The bootloader is unlocked.
- `adb` and `fastboot` are installed on the host computer.
- Important Android and internal-storage data has been backed up.
- The boot image and rootfs come from the same workflow run.
- A dual-boot installation has a GPT partition named `linux` that is larger
  than the rootfs logical size (currently about 10 GiB). If it already exists,
  skip the partition step below.

### Dual boot

#### 1. Create or verify the Linux partition

`fastboot` cannot shrink the GPT `userdata` partition and create `linux`. Skip
this step when `linux` already exists. Otherwise enter a recovery that can run
`parted` or `sgdisk`:

```sh
adb reboot recovery
```

From the bootloader, `fastboot reboot recovery` works when the device supports
that target. Otherwise run `fastboot reboot` and use the recovery key
combination.

In recovery, run only these read-only commands first. Do not guess the
whole-disk device name:

```sh
adb wait-for-device
adb shell 'id; getprop ro.bootmode'
adb shell 'ls -l /dev/block/by-name/userdata /dev/block/by-name/boot_a /dev/block/by-name/boot_b'
adb shell 'ls -l /dev/block/by-name/dtbo_a /dev/block/by-name/dtbo_b'
adb shell 'cat /proc/partitions'
adb shell 'command -v parted; command -v sgdisk; command -v mkfs.f2fs'
```

Use the `userdata` symlink target (for example `/dev/block/sdaXX`) to find the
parent disk (for example `/dev/block/sda`). Back up the GPT and print the
sector-based layout:

```sh
adb shell 'sgdisk --backup=/tmp/caihong-gpt.bin /dev/block/sda'
adb pull /tmp/caihong-gpt.bin ./caihong-gpt-before.bin
adb shell 'parted /dev/block/sda unit s print'
```

If recovery has no `sgdisk`, push a static `parted` and save its `print`
output before changing anything:

```sh
adb push /path/to/parted /tmp/parted
adb shell
chmod +x /tmp/parted
/tmp/parted /dev/block/sda
```

F2FS cannot be shrunk, so delete `userdata` and recreate it. Keep its original
start, end it at the split point, and give `linux` the space up to the original
`userdata` end. Replace every value in angle brackets:

```text
unit s
print
rm <userdata-number>
mkpart primary <original-userdata-start> <linux-start>
name <new-userdata-number> userdata
mkpart primary <linux-start> <original-userdata-end>
name <new-linux-number> linux
print
quit
```

Confirm the GPT names are exactly `userdata` and `linux`. Then reformat
userdata with the device's `mkfs.f2fs`. This deletes Android user data:

```sh
mkfs.f2fs -f /dev/block/by-name/userdata
```

Do not format `linux`; fastboot writes the ext4 sparse rootfs to it. If
`/dev/block/by-name` still shows the old layout, re-enter recovery first. Then
return to the bootloader:

```sh
exit
adb reboot bootloader
```

#### 2. Flash the images

Choose the Linux slot explicitly. This example uses slot B:

```sh
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
ROOTFS=caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash linux "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

Erase only the DTBO of the Linux slot. The Caihong DTB is inside the boot
image; keep the Android slot's DTBO intact.

### Single system

This overwrites `userdata` and deletes Android user data:

```sh
adb reboot bootloader
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-userdata-<kernel-release>.img
ROOTFS=caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash userdata "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

### First boot

The image has an empty `/etc/machine-id` and an `.autorelabel` marker. The
first boot relabels SELinux contexts and reboots. GNOME Initial Setup then
creates the user account. `caihong-grow-rootfs.service` expands the ext4
filesystem to fill its partition, and `caihong-mark-boot-successful.service`
marks the running slot successful.

## Updates

The image enables the `fairyband/caihong` Copr repository. Normal Fedora
updates also update the device packages:

```sh
sudo dnf upgrade --refresh
```

The Caihong `libcamera` and `ffmpeg` builds use `Epoch: 1` and DNF5 repository
overrides, so Fedora's packages do not replace them.

Kernel updates use two packages. `caihong-kernel-payload` carries the Image,
DTB, boot images and modules of one kernel release; it is built from a kernel
release archive, not by the normal Copr source build. `caihong-kernel-updater`
provides `caihong-kernel-install`, which starts
`caihong-kernel-install.service`. The service is also enabled at boot. It
detects the root partition label (`linux` or `userdata`), writes the matching
boot image to the running slot only, and reads it back to verify. The RPM
transaction itself never writes block devices, and the A/B active, bootable
and successful flags are not changed.

```sh
sudo dnf install ./caihong-kernel-payload-<version>.aarch64.rpm
sudo caihong-kernel-install
```

## Board utilities

These tools come from `caihong-device-support` under `/usr/local`. Commands
that change hardware or boot state need root.

| Utility | Purpose and example |
| --- | --- |
| `caihong-slot` | Inspect or switch A/B slots: `sudo caihong-slot status`, `sudo caihong-slot android --reboot`. |
| `caihong-flashlight` | Rear torch: `sudo caihong-flashlight on 40`, `status`, `off`. |
| `caihong-hotspot` | Concurrent Wi-Fi AP without dropping the STA: `sudo caihong-hotspot start`, `status`, `stop`, `regulatory {show\|set CODE\|reset}`. Configured in `/etc/caihong-hotspot.conf`. |
| `caihong-hardware-mac` | Applies the factory WLAN and Bluetooth addresses from NVRAM at boot. |
| `caihong-bluetooth-autostart` | Powers on the Bluetooth controller at boot. |
| `caihong-pen-pair`, `caihong-pen-charge`, `caihong-pen-autoconnect` | Pen pairing, charging observation and reconnection, run by systemd timers. |
| `caihong-mark-boot-successful` | Marks only the booted slot successful. Runs at boot. |
| `caihong-switch-to-android.desktop` | Application menu entry that reboots into Android through polkit. |

## Building locally

On an x86_64 Fedora host install `gcc-aarch64-linux-gnu`, `qemu-user-static`,
`rpm`, `rsync`, `e2fsprogs` and `android-tools` (`img2simg`). On an AArch64
host the native compiler is used and QEMU is not needed.

```sh
scripts/checkout-dependencies.sh
CROSS_COMPILE=aarch64-linux-gnu- scripts/build-kernel-release.sh
sudo -E env COPR_REPO=fairyband/caihong SELINUX_MODE=permissive \
  MODULE_TREE="$PWD/modules-current" RELEASE_DIR="$PWD/release" \
  scripts/package-fedora-rootfs.sh
```

The builder downloads the pinned Fedora 44 Workstation raw image and uses it
only as a content source. It enables the Copr, installs the Caihong device,
firmware, audio, SSC, camera and kernel-updater RPMs, overlays `rootfs/caihong/`,
installs the matching modules and boot payload, and writes a new
`LABEL=linux` ext4 image for the Android direct-root boot path. After the
service policies are ready, rebuild with `SELINUX_MODE=enforcing`. Run
`scripts/verify-fedora-rootfs.sh ROOTFS_DIR` on a mounted image to check it.

## Licensing

Project-authored build scripts and utilities are licensed under GPL-2.0-only
unless a file states another SPDX license. Camera tuning data keeps its stated
CC0 license. Bundled device firmware remains subject to its vendor terms.
