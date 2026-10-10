#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-}
if [ -z "$target" ] || [ ! -d "$target" ]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi
target=$(cd -- "$target" && pwd)

required_paths='etc/NetworkManager/conf.d/20-caihong-hardware-mac.conf
etc/NetworkManager/conf.d/30-caihong-hotspot.conf
etc/bluetooth/main.conf
etc/xdg/bluedevilglobalrc
etc/caihong-hotspot.conf
etc/caihong-pen.json
etc/modules-load.d/caihong.conf
etc/sudoers.d/10-alarm
etc/systemd/system/caihong-grow-rootfs.service
etc/systemd/system/caihong-fix-kwin-brightness.service
etc/systemd/system/caihong-clean-pogo-kde.service
etc/systemd/system/caihong-bluetooth-autostart.service
etc/systemd/system/caihong-hardware-mac.service
etc/systemd/system/caihong-hotspot.service
etc/systemd/system/caihong-mark-boot-successful.service
etc/systemd/system/caihong-pen-autoconnect.service
etc/systemd/system/caihong-pen-autoconnect.timer
etc/systemd/system/caihong-pen-charge.service
etc/systemd/system/caihong-pen-charge.timer
etc/systemd/system/caihong-pen-pair.service
etc/systemd/system/caihong-pen-pair.timer
etc/systemd/system/bluetooth.target.wants/bluetooth.service
etc/systemd/system/display-manager.service
etc/systemd/system/multi-user.target.wants/NetworkManager.service
etc/systemd/system/multi-user.target.wants/caihong-bluetooth-autostart.service
etc/systemd/system/multi-user.target.wants/caihong-hardware-mac.service
etc/systemd/system/multi-user.target.wants/caihong-mark-boot-successful.service
etc/systemd/system/graphical.target.wants/caihong-clean-pogo-kde.service
etc/systemd/system/multi-user.target.wants/caihong-ssc.service
etc/systemd/system/multi-user.target.wants/sshd.service
etc/systemd/system/timers.target.wants/caihong-pen-autoconnect.timer
etc/systemd/system/timers.target.wants/caihong-pen-charge.timer
etc/systemd/system/timers.target.wants/caihong-pen-pair.timer
usr/local/libexec/caihong-nvram-mac
usr/local/sbin/caihong-bluetooth-autostart
usr/local/sbin/caihong-hardware-mac
usr/local/sbin/caihong-hotspot
usr/local/sbin/caihong-flashlight
usr/local/sbin/caihong-fix-kwin-brightness
usr/local/sbin/caihong-clean-pogo-kde
usr/local/sbin/caihong-mark-boot-successful
usr/local/sbin/caihong-pen-autoconnect
usr/local/sbin/caihong-pen-charge
usr/local/sbin/caihong-pen-pair
usr/local/sbin/caihong-slot
usr/local/sbin/qbootctl
usr/share/applications/caihong-switch-to-android.desktop
usr/lib/linux-caihong/boot-linux.img
usr/lib/linux-caihong/boot-userdata.img
usr/lib/linux-caihong/install-current-slot
usr/lib/linux-caihong/kernel-release
usr/lib/modules-load.d/caihong.conf
usr/bin/cam
usr/bin/plasma-camera
usr/bin/qcam
usr/lib/gstreamer-1.0/libgstlibcamera.so
usr/lib/libcamera-base.so.0.7.2
usr/lib/libcamera.so.0.7
usr/lib/libcamera.so.0.7.2
usr/lib/libcamera/ipa/ipa_soft_simple.so
usr/lib/libcamera/ipa/ipa_soft_simple.so.sign
usr/libexec/libcamera/soft_ipa_proxy
usr/share/caihong/libcamera-build-info
usr/share/caihong/plasma-camera-build-info
usr/share/libcamera/ipa/simple/sc1320cs.yaml
usr/share/libcamera/ipa/simple/sc820cs.yaml
usr/share/alsa/ucm2/Qualcomm/sm8650/Caihong/HiFi.conf
usr/share/alsa/ucm2/conf.d/sm8650/SM8650-MTP.conf
usr/local/libexec/caihong-ssc/hexagonrpcd
usr/local/lib/caihong-ssc/libhexagonrpc.so.0.5
usr/lib/systemd/system/caihong-ssc.service
usr/lib/systemd/system/iio-sensor-proxy.service.d/caihong-ssc.conf
usr/lib/udev/rules.d/90-caihong-ssc.rules
var/lib/caihong-ssc/root/sensors/sns_reg.conf
etc/udev/rules.d/70-dma-heap.rules
etc/udev/rules.d/80-caihong-hotspot.rules
usr/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin
usr/lib/firmware/ath12k/WCN7850/hw2.0/caihong/amss.bin
usr/lib/firmware/ath12k/WCN7850/hw2.0/caihong/m3.bin
usr/lib/firmware/ath12k/WCN7850/hw2.0/caihong/regdb.bin
usr/lib/firmware/awinic/caihong-aw88261-acf.bin
usr/lib/firmware/awinic/caihong-aw88261-speaker-cal.bin
usr/lib/firmware/novatek/DT-novatek-nt36532.bin
usr/lib/firmware/qcom/sm8650/SM8650-MTP-tplg.bin'

failed=0

module_releases=()
for candidate in "$target"/usr/lib/modules/*; do
	[ -d "$candidate" ] || continue
	module_releases+=("${candidate##*/}")
done
if [ "${#module_releases[@]}" -ne 1 ]; then
	echo "rootfs must contain exactly one kernel module release" >&2
	failed=1
else
	kernel_release=${module_releases[0]}
	module_dir="$target/usr/lib/modules/$kernel_release"
	for metadata in modules.dep modules.alias modules.builtin; do
		if [ ! -s "$module_dir/$metadata" ]; then
			echo "missing kernel module metadata: $metadata" >&2
			failed=1
		fi
	done
	for module in oneplus_pogo nt36532e_ts sc8547_cp caihong_pen_power \
		bnep system_heap cma_heap sc820cs sc1320cs gt9772 ath12k_wifi7 \
		qcom_q6v5_pas; do
		module_file=$(find "$module_dir" -type f -name "$module.ko" -print -quit)
		if [ -z "$module_file" ]; then
			echo "missing release kernel module: $module" >&2
			failed=1
			continue
		fi
		vermagic=$(modinfo -F vermagic "$module_file" 2>/dev/null || true)
		case "$vermagic" in
			"$kernel_release"\ *) ;;
			*)
				echo "kernel module release mismatch: $module" >&2
				failed=1
				;;
		esac
	done
	pen_copy="$target/usr/local/lib/caihong/caihong_pen_power.ko"
	pen_installed=$(find "$module_dir" -type f -name caihong_pen_power.ko -print -quit)
	if [ -z "$pen_installed" ] || ! cmp -s "$pen_installed" "$pen_copy"; then
		echo "on-demand pen module does not match the release module tree" >&2
		failed=1
	fi
fi

libcamera_commit=$(git -C "$project_dir/external/libcamera" rev-parse --verify HEAD)
plasma_camera_commit=$(git -C "$project_dir/external/plasma-camera" rev-parse --verify HEAD)
if ! grep -qx "source_commit=$libcamera_commit" \
	"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null; then
	echo "rootfs libcamera source commit does not match the workspace" >&2
	failed=1
fi
if ! grep -qx "source_commit=$plasma_camera_commit" \
	"$target/usr/share/caihong/plasma-camera-build-info" 2>/dev/null; then
	echo "rootfs Plasma Camera source commit does not match the workspace" >&2
	failed=1
fi

for path in $required_paths; do
	if [ ! -e "$target/$path" ] && [ ! -L "$target/$path" ]; then
		echo "missing required rootfs path: /$path" >&2
		failed=1
	fi
done

package_db=$(find "$target/var/lib/pacman/local" -mindepth 1 -maxdepth 1 \
	-type d -name 'linux-caihong-*' -print -quit 2>/dev/null || true)
if [ -z "$package_db" ] || ! grep -qx 'linux-caihong' "$package_db/desc"; then
	echo "linux-caihong is not registered in the pacman database" >&2
	failed=1
fi
if [ ! -d "$target/usr/lib/linux-caihong/modules/$kernel_release" ]; then
	echo "linux-caihong private module payload is missing" >&2
	failed=1
fi
private_pen=$(find "$target/usr/lib/linux-caihong/modules/$kernel_release" \
	-type f -name caihong_pen_power.ko -print -quit)
active_pen=$(find "$target/usr/lib/modules/$kernel_release" \
	-type f -name caihong_pen_power.ko -print -quit)
if [ -z "$private_pen" ] || [ -z "$active_pen" ] || \
	[ "$(stat -c '%i' "$private_pen" 2>/dev/null)" != \
	"$(stat -c '%i' "$active_pen" 2>/dev/null)" ]; then
	echo "linux-caihong module payload was not hard-linked into the active tree" >&2
	failed=1
fi
if ! cmp -s "$target/usr/lib/linux-caihong/kernel-release" \
	<(printf '%s\n' "$kernel_release"); then
	echo "linux-caihong package release does not match its module tree" >&2
	failed=1
fi

if ! grep -qx 'AutoEnable=true' "$target/etc/bluetooth/main.conf"; then
	echo "BlueZ controller auto-enable policy is missing" >&2
	failed=1
fi
if ! grep -qx 'launchState=enable' "$target/etc/xdg/bluedevilglobalrc"; then
	echo "BlueDevil login policy does not enable Bluetooth" >&2
	failed=1
fi
if ! grep -qx 'alarm ALL=(ALL:ALL) ALL' "$target/etc/sudoers.d/10-alarm"; then
	echo "alarm sudo policy is missing" >&2
	failed=1
fi
if [ "$(stat -c '%a' "$target/etc/sudoers.d/10-alarm")" != 440 ]; then
	echo "alarm sudo policy must have mode 0440" >&2
	failed=1
fi
if ! grep -qx \
	'Exec=/usr/bin/pkexec /usr/local/sbin/caihong-slot android --reboot' \
	"$target/usr/share/applications/caihong-switch-to-android.desktop"; then
	echo "Caihong Android slot desktop action is incorrect" >&2
	failed=1
fi

# The downstream HMT 2.0 payload starts far enough to announce its version,
# but never reaches WMI ready with the ath12k_wifi7 baseline used here.  Verify
# every installed runtime payload so a stale root filesystem cannot silently
# combine that firmware with the release kernel.
if ! (cd -- "$target/usr/lib/firmware" &&
	sha256sum -c "$project_dir/firmware/SHA256SUMS" >/dev/null); then
	echo "installed runtime firmware does not match the Caihong release set" >&2
	failed=1
fi
wifi_amss="$target/usr/lib/firmware/ath12k/WCN7850/hw2.0/caihong/amss.bin"
wifi_version='QC_IMAGE_VERSION_STRING=WLAN.HMT.1.1.c7-00108-QCAHMTSWPL_V1.0_V2.0_SILICONZ_UPSTREAM-3'
if ! grep -aFq "$wifi_version" "$wifi_amss" 2>/dev/null; then
	echo "Caihong WLAN firmware is not the validated HMT 1.1.c7 build" >&2
	failed=1
fi

for setting in build=caihong pipelines=simple ipas=simple \
	softisp_gpu=enabled lens_shading=dynamic \
	lens_shading_calibration=nvmem-per-device \
	awb_calibration=nvmem-per-device auto_contrast=dynamic \
	ae_controls=full awb_controls=full \
	autofocus=contrast-detect \
	noise_reduction=dynamic sharpness=dynamic \
	camera_flash=dual-v4l2 \
	camera_flash_sync=frame-start-request-queue \
	camera_flash_torch_stop=led-mode \
	sensor_control_sync=raw-sof-timestamp \
	software_isp_startup_controls=enabled \
	frame_duration_limits=vblank-dynamic \
	ae_convergence=bounded-ratio \
	default_max_frame_duration_us=100000 \
	digital_gain_max=1.0 \
	gstreamer_camera_controls=flash-nr-cct \
	gstreamer=enabled qcam=enabled; do
	if ! grep -qx "$setting" \
		"$target/usr/share/caihong/libcamera-build-info" 2>/dev/null; then
		echo "missing Caihong libcamera build setting: $setting" >&2
		failed=1
	fi
done
for setting in build=caihong version=26.08.1 backend=libcamera-direct \
	autofocus=single-trigger white_balance=presets \
	noise_reduction=selectable sharpness=selectable \
	flash=off-single-torch \
	flash_torch_intensity=200000 flash_capture_intensity=500000 \
	video_frame_rate=libcamera-frame-duration \
	photo_quality=jpeg-95; do
	if ! grep -qx "$setting" \
		"$target/usr/share/caihong/plasma-camera-build-info" 2>/dev/null; then
		echo "missing Caihong Plasma Camera build setting: $setting" >&2
		failed=1
	fi
done
if ! awk '
	/^\[/ { in_options = ($0 == "[options]") }
	in_options && $0 == "IgnorePkg = libcamera libcamera-ipa libcamera-tools gst-plugin-libcamera plasma-camera" {
		found = 1
	}
	END { exit !found }
' "$target/etc/pacman.conf" 2>/dev/null; then
	echo "rootfs does not protect the Caihong libcamera build from package upgrades" >&2
	failed=1
fi
for sensor in sc1320cs sc820cs; do
	tuning="$target/usr/share/libcamera/ipa/simple/$sensor.yaml"
	case "$sensor" in
		sc1320cs) nvmem=sc1320cs-eeprom ;;
		sc820cs) nvmem=sc820cs-otp ;;
	esac
	if ! grep -q 'contrast: 1.1' "$tuning" 2>/dev/null || \
		! grep -q 'autoContrast:' "$tuning" 2>/dev/null || \
		! grep -q 'ct: 6500' "$tuning" 2>/dev/null || \
		! grep -q -- '- LensShading:' "$tuning" 2>/dev/null || \
		! grep -q 'calibration:' "$tuning" 2>/dev/null || \
		! grep -q 'records:' "$tuning" 2>/dev/null || \
		! grep -q "nvmem: $nvmem" "$tuning" 2>/dev/null || \
		! grep -q 'flip-x: true' "$tuning" 2>/dev/null || \
		! grep -q 'exposure-ms:' "$tuning" 2>/dev/null; then
		echo "incomplete Caihong camera tuning: $tuning" >&2
		failed=1
	fi
done

if [ -e \
	"$target/usr/lib/qt6/plugins/powerdevil/action/powerdevil_keyboardbrightnesscontrolaction.so" ]; then
	echo "rootfs still contains the unsupported PowerDevil keyboard-backlight action" >&2
	failed=1
fi

required_packages='bluez bluez-utils openssh networkmanager hostapd dnsmasq nftables pipewire
pipewire-pulse wireplumber alsa-utils iio-sensor-proxy libssc libcamera
libcamera-ipa libcamera-tools gst-plugin-libcamera plasma-camera krita firefox
python-jinja python-ply python-yaml qt6-tools'
package_db=$target/var/lib/pacman/local
for package in $required_packages; do
	if ! find "$package_db" -mindepth 1 -maxdepth 1 -type d \
		-name "$package-[0-9]*" -print -quit | grep -q .; then
		echo "missing required rootfs package: $package" >&2
		failed=1
	fi
done

if [ "$failed" -ne 0 ]; then
	exit 1
fi

echo "Caihong rootfs verification passed"
