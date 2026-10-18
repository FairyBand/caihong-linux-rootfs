#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
linux_dir=${LINUX_DIR:-"$project_dir/linux"}
kernel_out=${KERNEL_OUT:-"$project_dir/build/linux"}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
if [ "${CROSS_COMPILE+x}" = x ]; then
	cross_compile=$CROSS_COMPILE
else
	case $(uname -m) in
		aarch64|arm64) cross_compile= ;;
		*) cross_compile=aarch64-linux-gnu- ;;
	esac
fi
kernel_cc=${KERNEL_CC:-${cross_compile}gcc}
kernel_hostcc=${KERNEL_HOSTCC:-gcc}
cpu_count=$(nproc)
if [ "$cpu_count" -gt 1 ]; then jobs_default=$((cpu_count - 1)); else jobs_default=1; fi
jobs=${JOBS:-$jobs_default}
firmware_dir="$project_dir/firmware"
early_firmware="qcom/gen70900_sqe.fw qcom/gmu_gen70900.bin"
selinux_fragment="$project_dir/packaging/kernel/caihong-fedora-selinux.config"

(cd "$firmware_dir" && sha256sum -c SHA256SUMS)

for file in $early_firmware; do
	[ -f "$firmware_dir/$file" ] || {
		echo "missing early GPU firmware: $firmware_dir/$file" >&2
		exit 1
	}
done
[ -f "$linux_dir/Makefile" ] || { echo "missing Linux tree: $linux_dir" >&2; exit 1; }
mkdir -p "$kernel_out" "$release_dir"

make -C "$linux_dir" O="$kernel_out" ARCH=arm64 \
	CROSS_COMPILE="$cross_compile" CC="$kernel_cc" HOSTCC="$kernel_hostcc" \
	caihong_defconfig

# The upstream Caihong defconfig intentionally targets a small generic
# userspace and does not enable SELinux.  Apply the Fedora fragment after the
# defconfig, then let Kconfig resolve all transitive dependencies.
[ -f "$selinux_fragment" ] || {
	echo "missing Fedora SELinux config fragment: $selinux_fragment" >&2
	exit 1
}
while IFS= read -r setting || [ -n "$setting" ]; do
	case "$setting" in
	''|'#'*) continue ;;
	CONFIG_*=*)
		key=${setting%%=*}
		sed -i -e "/^${key}=.*/d" -e "/^# ${key} is not set$/d" \
			"$kernel_out/.config"
		printf '%s\n' "$setting" >> "$kernel_out/.config"
		;;
	*)
		echo "invalid kernel config fragment line: $setting" >&2
		exit 1
		;;
	esac
done < "$selinux_fragment"
make -C "$linux_dir" O="$kernel_out" ARCH=arm64 \
	CROSS_COMPILE="$cross_compile" CC="$kernel_cc" HOSTCC="$kernel_hostcc" \
	olddefconfig

config_value()
{
	key=$1
	value=$(sed -n -e "s/^${key}=//p" -e "s/^# ${key} is not set$/n/p" \
		"$kernel_out/.config" | tail -n 1)
	printf '%s\n' "${value:-n}"
}

for setting in \
	CONFIG_SECURITY_NETWORK=y \
	CONFIG_SECURITY_PATH=y \
	CONFIG_SECURITY_SELINUX=y \
	CONFIG_SECURITY_SELINUX_BOOTPARAM=y \
	CONFIG_SECURITY_SELINUX_DEVELOP=y \
	CONFIG_DEFAULT_SECURITY_SELINUX=y \
	CONFIG_SECURITYFS=y \
	CONFIG_AUDIT=y \
	CONFIG_NET=y \
	CONFIG_INET=y \
	CONFIG_NETWORK_SECMARK=y \
	'CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf,ipe"'; do
	key=${setting%%=*}
	expected=${setting#*=}
	actual=$(config_value "$key")
	[ "$actual" = "$expected" ] || {
		echo "kernel configuration missing Fedora SELinux requirement: $setting (got $actual)" >&2
		exit 1
	}
done
for setting in \
	CONFIG_DEVTMPFS=y CONFIG_DEVTMPFS_MOUNT=y CONFIG_EFI_PARTITION=y \
	CONFIG_SCSI=y CONFIG_BLK_DEV_SD=y CONFIG_SCSI_UFSHCD=y \
	CONFIG_SCSI_UFS_QCOM=y CONFIG_PHY_QCOM_QMP_UFS=y CONFIG_EXT4_FS=y \
	'CONFIG_INITRAMFS_SOURCE=""'; do
	grep -qx "$setting" "$kernel_out/.config" || {
		echo "kernel configuration missing direct-root requirement: $setting" >&2
		exit 1
	}
done

make -C "$linux_dir" O="$kernel_out" ARCH=arm64 \
	CROSS_COMPILE="$cross_compile" \
	CC="$kernel_cc" HOSTCC="$kernel_hostcc" \
	CONFIG_EXTRA_FIRMWARE="$early_firmware" \
	CONFIG_EXTRA_FIRMWARE_DIR="$firmware_dir" \
	-j"$jobs" Image modules qcom/sm8650-oneplus-caihong.dtb

rm -rf -- "$module_tree"
make -C "$linux_dir" O="$kernel_out" ARCH=arm64 \
	CROSS_COMPILE="$cross_compile" \
	CC="$kernel_cc" HOSTCC="$kernel_hostcc" \
	INSTALL_MOD_PATH="$module_tree" modules_install

kernel_release=$(make -s -C "$linux_dir" O="$kernel_out" ARCH=arm64 \
	CROSS_COMPILE="$cross_compile" CC="$kernel_cc" HOSTCC="$kernel_hostcc" \
	kernelrelease)
image="$kernel_out/arch/arm64/boot/Image"
dtb="$kernel_out/arch/arm64/boot/dts/qcom/sm8650-oneplus-caihong.dtb"
for root_partlabel in linux userdata; do
	boot_image="$release_dir/caihong-boot-$root_partlabel-$kernel_release.img"
	manifest="$boot_image.json"
	case "$root_partlabel" in
		linux) cmdline_file="$project_dir/caihong-direct-root-cmdline.txt" ;;
		userdata) cmdline_file="$project_dir/caihong-direct-root-userdata-cmdline.txt" ;;
	esac

	FORCE=${FORCE:-0} ROOT_PARTLABEL=$root_partlabel \
		CMDLINE_FILE="$cmdline_file" \
		"$project_dir/scripts/build-boot-v2.sh" "$boot_image" "$image" "$dtb"
	"$project_dir/scripts/verify-caihong-release.py" "$boot_image" \
		--kernel "$image" \
		--dtb "$dtb" \
		--config "$kernel_out/.config" \
		--module-tree "$module_tree" \
		--firmware-dir "$firmware_dir" \
		--root-partlabel "$root_partlabel" \
		--manifest "$manifest"
done

install -m 0644 "$image" "$release_dir/Image-$kernel_release"
install -m 0644 "$dtb" "$release_dir/sm8650-oneplus-caihong-$kernel_release.dtb"
install -m 0644 "$kernel_out/.config" "$release_dir/config-$kernel_release"
printf '%s\n' "$kernel_release" > "$release_dir/KERNEL_RELEASE"
sha256sum "$release_dir"/caihong-boot-linux-"$kernel_release".img \
	"$release_dir"/caihong-boot-userdata-"$kernel_release".img \
	"$release_dir"/Image-"$kernel_release" \
	"$release_dir"/sm8650-oneplus-caihong-"$kernel_release".dtb \
	> "$release_dir/SHA256SUMS.boot"
echo "kernel release prepared: $kernel_release"
