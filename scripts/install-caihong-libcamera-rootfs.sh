#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-}
chroot_tool=${CHROOT_TOOL:-arch-chroot}
jobs=${LIBCAMERA_BUILD_JOBS:-}

if [[ -z $rootfs || ! -d $rootfs ]]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi

rootfs=$(CDPATH= cd -- "$rootfs" && pwd)
case "$rootfs" in
	/|/boot|/home|/usr|/var)
		echo "refusing unsafe rootfs directory: $rootfs" >&2
		exit 1
		;;
esac

source_tree="$project_dir/external/libcamera"
if [[ ! -f $source_tree/meson.build || \
	! -f $source_tree/src/ipa/simple/data/sc1320cs.yaml || \
	! -f $source_tree/src/ipa/simple/data/sc820cs.yaml ]]; then
	echo "incomplete Caihong libcamera source tree: $source_tree" >&2
	exit 1
fi

for tool in "$chroot_tool" git nproc rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
	echo "refusing to package uncommitted libcamera source changes" >&2
	exit 1
fi
source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)

if [[ -z $jobs ]]; then
	jobs=$(nproc)
	if (( jobs > 1 )); then
		((jobs -= 1))
	fi
	# Native device builds use seven workers and keep one CPU free. Capping
	# rootfs builds also avoids excessive memory use under QEMU user-mode.
	if (( jobs > 7 )); then
		jobs=7
	fi
fi
case "$jobs" in
	''|*[!0-9]*|0)
		echo "LIBCAMERA_BUILD_JOBS must be a positive integer" >&2
		exit 1
		;;
esac

source_stage="$rootfs/var/tmp/libcamera-caihong-src"
build_stage="$rootfs/var/tmp/libcamera-caihong-build"
install_stage="$rootfs/var/tmp/libcamera-caihong-install"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
mkdir -p "$source_stage"
rsync -a --delete \
	--exclude='/.git/' \
	--exclude='/build*/' \
	--exclude='/.cache/' \
	--exclude='**/__pycache__/' \
	"$source_tree/" "$source_stage/"
printf '0.7.2+caihong\n' > "$source_stage/.tarball-version"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/bin)
source_inside=/var/tmp/libcamera-caihong-src
build_inside=/var/tmp/libcamera-caihong-build
install_inside=/var/tmp/libcamera-caihong-install

echo "configuring Caihong libcamera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	meson setup "$build_inside" "$source_inside" \
	--buildtype=release \
	--prefix=/usr \
	--sysconfdir=/etc \
	--libdir=lib \
	-Dwerror=false \
	-Dandroid=disabled \
	-Dcam=enabled \
	-Ddocumentation=disabled \
	-Dgstreamer=enabled \
	-Dipas=simple \
	-Dlc-compliance=disabled \
	-Dpipelines=simple \
	-Dpycamera=disabled \
	-Dqcam=enabled \
	-Dsoftisp-gpu=enabled \
	-Dtest=false \
	-Dtracing=disabled \
	-Dv4l2=disabled

echo "building Caihong libcamera with $jobs workers"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	ninja -C "$build_inside" -j "$jobs"

echo "staging Caihong libcamera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	DESTDIR="$install_inside" ninja -C "$build_inside" install

required_outputs=(
	usr/bin/cam
	usr/bin/qcam
	usr/lib/gstreamer-1.0/libgstlibcamera.so
	usr/lib/libcamera-base.so.0.7.2
	usr/lib/libcamera.so.0.7
	usr/lib/libcamera.so.0.7.2
	usr/lib/libcamera/ipa/ipa_soft_simple.so
	usr/lib/libcamera/ipa/ipa_soft_simple.so.sign
	usr/libexec/libcamera/soft_ipa_proxy
	usr/share/libcamera/ipa/simple/sc1320cs.yaml
	usr/share/libcamera/ipa/simple/sc820cs.yaml
)
for path in "${required_outputs[@]}"; do
	if [[ ! -e $install_stage/$path ]]; then
		echo "custom libcamera install is missing /$path" >&2
		exit 1
	fi
done

echo "installing Caihong libcamera into rootfs"
rsync -aHAX --numeric-ids --chown=0:0 "$install_stage/" "$rootfs/"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" ldconfig

install -d -m 0755 "$rootfs/usr/share/caihong"
cat > "$rootfs/usr/share/caihong/libcamera-build-info" <<EOF
build=caihong
version=0.7.2+caihong
source_commit=$source_commit
pipelines=simple
ipas=simple
softisp_gpu=enabled
lens_shading=dynamic
lens_shading_calibration=nvmem-per-device
awb_calibration=nvmem-per-device
auto_contrast=dynamic
ae_controls=full
awb_controls=full
autofocus=contrast-detect
noise_reduction=dynamic
sharpness=dynamic
camera_flash=dual-v4l2
camera_flash_sync=frame-start-request-queue
camera_flash_torch_stop=led-mode
sensor_control_sync=raw-sof-timestamp
software_isp_startup_controls=enabled
frame_duration_limits=vblank-dynamic
ae_convergence=bounded-ratio
default_max_frame_duration_us=100000
digital_gain_max=1.0
gstreamer_camera_controls=flash-nr-cct
gstreamer=enabled
qcam=enabled
build_jobs=$jobs
EOF
chmod 0644 "$rootfs/usr/share/caihong/libcamera-build-info"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
echo "Caihong libcamera installed into $rootfs"
