#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rootfs=${1:-}
chroot_tool=${CHROOT_TOOL:-arch-chroot}
jobs=${PLASMA_CAMERA_BUILD_JOBS:-}

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

source_tree="$project_dir/external/plasma-camera"
if [[ ! -f $source_tree/CMakeLists.txt || \
	! -f $source_tree/src/plasmacamera.cpp || \
	! -f $source_tree/src/contents/ui/camera/CameraPage.qml ]]; then
	echo "incomplete Caihong Plasma Camera source tree: $source_tree" >&2
	exit 1
fi

for tool in "$chroot_tool" git nproc rsync; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "missing host tool: $tool" >&2
		exit 1
	fi
done

if [[ -n $(git -C "$source_tree" status --porcelain --untracked-files=no) ]]; then
	echo "refusing to package uncommitted Plasma Camera source changes" >&2
	exit 1
fi
source_commit=$(git -C "$source_tree" rev-parse --verify HEAD)

if [[ -z $jobs ]]; then
	jobs=$(nproc)
	if (( jobs > 1 )); then
		((jobs -= 1))
	fi
	if (( jobs > 7 )); then
		jobs=7
	fi
fi
case "$jobs" in
	''|*[!0-9]*|0)
		echo "PLASMA_CAMERA_BUILD_JOBS must be a positive integer" >&2
		exit 1
		;;
esac

source_stage="$rootfs/var/tmp/plasma-camera-caihong-src"
build_stage="$rootfs/var/tmp/plasma-camera-caihong-build"
install_stage="$rootfs/var/tmp/plasma-camera-caihong-install"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
mkdir -p "$source_stage"
rsync -a --delete \
	--exclude='/.git/' \
	--exclude='/build*/' \
	--exclude='/.cache/' \
	"$source_tree/" "$source_stage/"

chroot_env=(/usr/bin/env -i HOME=/root LANG=C
	PATH=/usr/local/sbin:/usr/local/bin:/usr/bin)
source_inside=/var/tmp/plasma-camera-caihong-src
build_inside=/var/tmp/plasma-camera-caihong-build
install_inside=/var/tmp/plasma-camera-caihong-install

echo "configuring Caihong Plasma Camera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	cmake -S "$source_inside" -B "$build_inside" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX=/usr \
	-DBUILD_TESTING=OFF

echo "building Caihong Plasma Camera with $jobs workers"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	cmake --build "$build_inside" --parallel "$jobs"

echo "staging Caihong Plasma Camera"
"$chroot_tool" "$rootfs" "${chroot_env[@]}" \
	/usr/bin/env DESTDIR="$install_inside" \
	cmake --install "$build_inside"

for path in usr/bin/plasma-camera usr/share/applications/org.kde.plasma.camera.desktop; do
	if [[ ! -e $install_stage/$path ]]; then
		echo "custom Plasma Camera install is missing /$path" >&2
		exit 1
	fi
done

echo "installing Caihong Plasma Camera into rootfs"
rsync -aHAX --numeric-ids --chown=0:0 "$install_stage/" "$rootfs/"

install -d -m 0755 "$rootfs/usr/share/caihong"
cat > "$rootfs/usr/share/caihong/plasma-camera-build-info" <<EOF
build=caihong
version=26.08.1
source_commit=$source_commit
backend=libcamera-direct
autofocus=single-trigger
white_balance=presets
noise_reduction=selectable
sharpness=selectable
flash=off-single-torch
flash_torch_intensity=200000
flash_capture_intensity=500000
video_frame_rate=libcamera-frame-duration
photo_quality=jpeg-95
build_jobs=$jobs
EOF
chmod 0644 "$rootfs/usr/share/caihong/plasma-camera-build-info"

rm -rf -- "$source_stage" "$build_stage" "$install_stage"
echo "Caihong Plasma Camera installed into $rootfs"
