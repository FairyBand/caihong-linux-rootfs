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
	etc/systemd/sleep.conf.d/10-caihong-s2idle.conf \
	usr/lib/systemd/system/caihong-ssc.service \
	usr/lib/systemd/system/iio-sensor-proxy.service.d/caihong-ssc.conf \
	usr/lib/linux-caihong/Image usr/lib/linux-caihong/caihong.dtb \
	usr/lib/linux-caihong/boot-linux.img usr/lib/linux-caihong/boot-userdata.img \
	usr/lib/linux-caihong/kernel-release usr/lib/linux-caihong/install-current-slot \
	usr/local/sbin/qbootctl usr/local/libexec/caihong-nvram-mac \
	usr/lib/firmware/updates/qcom/sm8650/SM8650-MTP-tplg.bin \
	usr/lib/firmware/qcom/sm8650/CAMERA_ICP.mbn \
	usr/lib/udev/rules.d/99-caihong-flashlight.rules \
	etc/modules-load.d/caihong.conf; do
	require_path "$path"
done
if ! grep -qx 'MemorySleepMode=s2idle' \
	"$target/etc/systemd/sleep.conf.d/10-caihong-s2idle.conf" 2>/dev/null; then
	echo "systemd memory sleep mode is not configured for s2idle" >&2
	failed=1
fi
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
if ! grep -qsE '^priority=[0-9]+$' "$target/etc/dnf/repos.override.d/90-caihong-copr.repo"; then
	echo "Caihong Copr priority override is missing" >&2
	failed=1
fi
# The builder records every Copr package it installed, with the Copr EVR.
mapfile -t copr_records < <(sed -n 's/^copr_package=//p' "$target/etc/caihong-rootfs-build-info" 2>/dev/null)
if (( ${#copr_records[@]} == 0 )); then
	echo "build metadata lists no Copr packages" >&2
	failed=1
fi
for package in caihong-audio caihong-device-support caihong-firmware caihong-kernel-updater \
	caihong-qbootctl caihong-ssc libcamera libcamera-ipa libavcodec-free; do
	printf '%s\n' "${copr_records[@]}" | grep -q "^$package " ||
		{ echo "build metadata does not list Copr package $package" >&2; failed=1; }
done
# Standalone camera applications are left out; GNOME uses Snapshot via PipeWire.
if printf '%s\n' "${copr_records[@]}" | grep -Eq '^(plasma-camera|libcamera-qcam)(-debuginfo|-debugsource)? '; then
	echo "build metadata lists an excluded camera application" >&2
	failed=1
fi
if ! command -v rpm >/dev/null 2>&1; then
	echo "rpm is required to verify installed Fedora packages" >&2
	failed=1
else
	for package in plasma-camera libcamera-qcam; do
		if rpm --root "$target" -q "$package" >/dev/null 2>&1; then
			echo "excluded camera application $package is installed" >&2
			failed=1
		fi
	done
	for record in "${copr_records[@]}"; do
		package=${record%% *} expected=${record#* }
		package_evr=$(rpm --root "$target" -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$package" 2>/dev/null || true)
		if [[ $package_evr != "$expected" ]]; then
			echo "Copr package $package is ${package_evr:-not installed}, expected $expected" >&2
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
	# The display driver may be built in or modular depending on the kernel
	# fragment, but Camera ICP/BPS must be present as modules for the ISP
	# pipeline to probe.
	if ! grep -q '/msm\.ko$' "$module_dir/modules.builtin"; then
		msm_module=$(find "$module_dir" -type f -name msm.ko -print -quit)
		if [ -z "$msm_module" ]; then
			echo "missing release kernel module: msm" >&2
			failed=1
		elif ! modinfo -F vermagic "$msm_module" 2>/dev/null |
			grep -q "^${releases[0]} "; then
			echo "kernel module release mismatch: msm" >&2
			failed=1
		fi
	fi
	for module in qcom_camera_icp qcom-camera-icp-bps; do
		if ! find "$module_dir" -type f -name "$module.ko" -print -quit | grep -q .; then
			echo "missing Fedora camera module: $module" >&2
			failed=1
		fi
	done
fi
(( failed == 0 )) || exit 1
echo "verified Caihong Fedora rootfs: $target"
