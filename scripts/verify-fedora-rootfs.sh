#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -Eeuo pipefail
CDPATH=

target=${1:-}
[[ -n $target && -d $target ]] || { echo "usage: $0 ROOTFS_DIR" >&2; exit 2; }
target=$(cd -- "$target" && pwd)
failed=0
missing() { echo "missing Fedora rootfs path: /$1" >&2; failed=1; }
require_path() { [[ -e $target/$1 || -L $target/$1 ]] || missing "$1"; }

grep -qx 'ID=fedora' "$target/usr/lib/os-release" 2>/dev/null || { echo "rootfs is not Fedora" >&2; failed=1; }
grep -qx 'SELINUXTYPE=targeted' "$target/etc/selinux/config" 2>/dev/null || { echo "SELinux targeted policy is not configured" >&2; failed=1; }
grep -Eq '^SELINUX=(permissive|enforcing)$' "$target/etc/selinux/config" 2>/dev/null || { echo "invalid SELinux mode" >&2; failed=1; }
grep -qx 'distribution=fedora' "$target/etc/caihong-rootfs-build-info" 2>/dev/null || { echo "missing Fedora build metadata" >&2; failed=1; }
grep -qx 'LABEL=linux / ext4 rw,noatime 0 1' "$target/etc/fstab" 2>/dev/null || { echo "root filesystem fstab entry is not configured for LABEL=linux" >&2; failed=1; }
for path in \
	etc/selinux/config \
	usr/lib/systemd/system/caihong-ssc.service \
	usr/lib/systemd/system/iio-sensor-proxy.service.d/caihong-ssc.conf \
	usr/lib/linux-caihong/Image usr/lib/linux-caihong/caihong.dtb \
	usr/lib/linux-caihong/boot-linux.img usr/lib/linux-caihong/boot-userdata.img \
	usr/lib/linux-caihong/kernel-release usr/lib/linux-caihong/install-current-slot \
	usr/local/sbin/qbootctl usr/local/libexec/caihong-nvram-mac \
	usr/lib/firmware/updates/qcom/sm8650/SM8650-MTP-tplg.bin \
	etc/modules-load.d/caihong.conf; do
	require_path "$path"
done
for module in snd-pcm snd-pcm-dmaengine snd-soc-core snd-q6apm q6prm \
	q6apm-dai q6apm-lpass-dais snd-soc-wcd939x-sdw snd-soc-aw88261 \
	snd-soc-sc8280xp; do
	if ! grep -Eq "^${module//-/_}$|^$module$" "$target/etc/modules-load.d/caihong.conf"; then
		echo "Fedora audio module is not listed for boot loading: $module" >&2
		failed=1
	fi
done
if ! grep -RqsE 'fairyband[^[:space:]/:]*[:/]caihong|fairyband/caihong' \
	"$target/etc/yum.repos.d" "$target/etc/dnf" 2>/dev/null; then
	echo "Caihong Copr repository is not configured" >&2
	failed=1
fi
camera_packages=(libcamera libcamera-ipa libcamera-tools libcamera-qcam libcamera-gstreamer plasma-camera)
device_packages=(caihong-audio caihong-device-support caihong-firmware caihong-kernel-updater caihong-qbootctl caihong-ssc)
if ! command -v rpm >/dev/null 2>&1; then
	echo "rpm is required to verify installed Fedora packages" >&2
	failed=1
else
	for package in "${camera_packages[@]}" "${device_packages[@]}"; do
		package_evr=$(rpm --root "$target" -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$package" 2>/dev/null || true)
		expected='*caihong*'
		case "$package" in
			libcamera*|plasma-camera) expected='1:*caihong*' ;;
		esac
		# shellcheck disable=SC2053 # $expected is a glob pattern
		if [[ -z $package_evr || $package_evr != $expected ]]; then
			echo "Fedora rootfs package is missing or not a Caihong build: $package (${package_evr:-not installed})" >&2
			failed=1
		fi
	done
fi
mapfile -t releases < <(find "$target/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
if (( ${#releases[@]} != 1 )); then
	echo "Fedora rootfs must contain exactly one module release" >&2; failed=1
else
	[[ -s $target/usr/lib/modules/${releases[0]}/modules.dep ]] || missing "usr/lib/modules/${releases[0]}/modules.dep"
	module_dir="$target/usr/lib/modules/${releases[0]}"
	[[ $(<"$target/usr/lib/linux-caihong/kernel-release") == "${releases[0]}" ]] || { echo "kernel release metadata mismatch" >&2; failed=1; }
	for module in snd-pcm snd-pcm-dmaengine snd-soc-core snd-q6apm q6prm \
		q6apm-dai q6apm-lpass-dais snd-soc-wcd939x-sdw snd-soc-aw88261 \
		snd-soc-sc8280xp; do
		if ! find "$module_dir" -type f -name "$module.ko" -print -quit | grep -q .; then
			echo "missing Fedora audio module: $module" >&2
			failed=1
		fi
	done
fi
(( failed == 0 )) || exit 1
echo "verified Caihong Fedora rootfs: $target"
