#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
release_dir=${RELEASE_DIR:-"$project_dir/release"}
kernel_release_file="$release_dir/KERNEL_RELEASE"
kernel_release=${KERNEL_RELEASE:-}
[[ -n $kernel_release ]] || [[ -f $kernel_release_file ]] || { echo "missing release/KERNEL_RELEASE" >&2; exit 1; }
[[ -n $kernel_release ]] || kernel_release=$(<"$kernel_release_file")
output=${1:-"$release_dir/caihong-fedora-rootfs-$kernel_release.ext4.sparse.img"}
fedora_image=${FEDORA_IMAGE:-"$project_dir/downloads/Fedora-Workstation-Disk-44-1.7.aarch64.raw.xz"}
fedora_image_url=${FEDORA_IMAGE_URL:-"https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/images/Fedora-Workstation-Disk-44-1.7.aarch64.raw.xz"}
fedora_image_sha256=${FEDORA_IMAGE_SHA256:-0361c13141e6f57e24d6ee5227066c33a45f7f92a95f41d0bbd343e4fd05da18}
module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
copr_repo=${COPR_REPO:-fairyband/caihong}
copr_repo_id="copr:copr.fedorainfracloud.org:${copr_repo//\//:}"
# Install every binary package in the Copr by default, including devel and
# debug packages, except the standalone camera applications below. GNOME uses
# Snapshot through PipeWire, and nothing depends on Plasma Camera or qcam. Set
# COPR_EXCLUDE_REGEX to omit further names.
copr_app_exclude_regex='^(plasma-camera|libcamera-qcam)(-debuginfo|-debugsource)?$'
copr_exclude_regex=$copr_app_exclude_regex${COPR_EXCLUDE_REGEX:+|$COPR_EXCLUDE_REGEX}
# Repository priority 10 beats Fedora's default 99: a package name present in
# the Copr is always taken from the Copr, even when Fedora has a newer EVR.
# caihong-device-support installs the same setting for later dnf runs.
copr_priority=${COPR_PRIORITY:-10}
selinux_mode=${SELINUX_MODE:-permissive}
image_min_free_mib=${IMAGE_MIN_FREE_MIB:-2048}
image_slack_percent=${IMAGE_SLACK_PERCENT:-25}
sparse_image=${SPARSE_IMAGE:-1}
force=${FORCE:-0}

fail() { echo "package-fedora-rootfs: $*" >&2; exit 1; }
[[ $selinux_mode == permissive || $selinux_mode == enforcing ]] || fail "SELINUX_MODE must be permissive or enforcing"
[[ $sparse_image == 0 || $sparse_image == 1 ]] || fail "SPARSE_IMAGE must be 0 or 1"
[[ $force == 0 || $force == 1 ]] || fail "FORCE must be 0 or 1"
[[ $copr_priority =~ ^[0-9]+$ ]] || fail "COPR_PRIORITY must be a number"
case "$image_min_free_mib:$image_slack_percent" in *[!0-9:]*|:*|*:) fail "invalid image sizing option" ;; esac
(( EUID == 0 )) || fail "run this script as root"
case $(uname -m) in
	aarch64|arm64) qemu_static= ;;
	*)
		qemu_static=${QEMU_AARCH64_STATIC:-qemu-aarch64-static}
		qemu_static=$(command -v "$qemu_static" 2>/dev/null) || \
			fail "x86_64 rootfs assembly requires qemu-aarch64-static"
		;;
esac

required_tools=(awk blkid chroot curl depmod du e2fsck findmnt img2simg losetup lsblk partx
	mkfs.ext4 modprobe mount mountpoint rsync sha256sum systemctl truncate umount
	xz zstd)
for tool in "${required_tools[@]}"; do command -v "$tool" >/dev/null 2>&1 || fail "missing host tool: $tool"; done
[[ -d "$module_tree/lib/modules/$kernel_release" ]] || fail "missing module tree for $kernel_release"
for input in \
	"$release_dir/Image-$kernel_release" \
	"$release_dir/sm8650-oneplus-caihong-$kernel_release.dtb" \
	"$release_dir/caihong-boot-linux-$kernel_release.img" \
	"$release_dir/caihong-boot-userdata-$kernel_release.img"; do
	[[ -f $input ]] || fail "missing kernel release input: $input"
done

mkdir -p "$project_dir/build" "$project_dir/downloads" "$(dirname -- "$output")"
output=$(cd -- "$(dirname -- "$output")" && pwd)/$(basename -- "$output")
[[ ! -e $output || $force == 1 ]] || fail "refusing to overwrite $output; set FORCE=1"
temporary="$output.new"
work_dir=$(mktemp -d "$project_dir/build/fedora-rootfs.XXXXXX")
source_raw="$work_dir/fedora.raw"; source_mount="$work_dir/source-mount"
rootfs="$work_dir/rootfs"; image_mount="$work_dir/image-mount"; raw_image="$work_dir/rootfs.raw.img"
source_loop=; source_partition_loop=; source_mounted=0; rootfs_mounted=0; image_mounted=0
source_offset=; source_size=

cleanup()
{
	status=$?; trap - EXIT HUP INT TERM
	if (( image_mounted )); then umount "$image_mount" 2>/dev/null || true; fi
	if (( rootfs_mounted )); then
		for api in dev proc sys run; do umount --lazy "$rootfs/$api" 2>/dev/null || true; done
		umount --lazy "$rootfs" 2>/dev/null || true
	fi
	if (( source_mounted )); then umount "$source_mount" 2>/dev/null || true; fi
	if [[ -n $source_loop ]]; then losetup -d "$source_loop" 2>/dev/null || true; fi
	if [[ -n $source_partition_loop ]]; then losetup -d "$source_partition_loop" 2>/dev/null || true; fi
	rm -rf -- "$work_dir"; rm -f -- "$temporary"; exit "$status"
}
report_error()
{
	status=$?
	printf 'package-fedora-rootfs: command failed (status %s): %s\n' \
		"$status" "$BASH_COMMAND" >&2
	[[ -n ${package:-} ]] && printf 'package-fedora-rootfs: package=%s\n' "$package" >&2
}
trap report_error ERR
trap cleanup EXIT HUP INT TERM

if [[ ! -f $fedora_image ]]; then
	echo "downloading Fedora image: $fedora_image_url"
	curl --fail --location --retry 4 --output "$fedora_image" "$fedora_image_url"
fi
if [[ -n $fedora_image_sha256 ]]; then
	actual_image_sha256=$(sha256sum "$fedora_image" | awk '{ print $1 }')
	[[ $actual_image_sha256 == "$fedora_image_sha256" ]] || fail "Fedora image SHA-256 mismatch"
fi
case "$fedora_image" in *.xz) xz -dc -- "$fedora_image" > "$source_raw" ;; *) cp --reflink=auto -- "$fedora_image" "$source_raw" ;; esac

# The Fedora raw image is only a package/content source.  Its Btrfs root
# subvolume, when present, is copied into a temporary directory; the device
# image below is always rebuilt as ext4 for the Android direct-root boot path.
echo "mounting Fedora source root"
source_loop=$(losetup --find --show --partscan --read-only "$source_raw")
source_partition=$(lsblk -lnpo NAME,FSTYPE "$source_loop" | awk '$2 == "btrfs" { print $1; exit }')
if [[ -z $source_partition ]]; then
	# Some hosts do not expose partition loop nodes even with --partscan.  Probe
	# the raw image's partition table directly and mount the detected filesystem
	# through a byte offset instead.
	fallback_offset=; fallback_size=
	while read -r _partition_number partition_start partition_sectors _partition_type; do
		[[ $partition_start =~ ^[0-9]+$ && $partition_sectors =~ ^[0-9]+$ ]] || continue
		partition_offset=$((partition_start * 512))
		partition_size=$((partition_sectors * 512))
		partition_fstype=$(blkid -p -o value -s TYPE -O "$partition_offset" -S "$partition_size" "$source_raw" 2>/dev/null || true)
		case "$partition_fstype" in
			btrfs)
				source_partition=$source_raw
				source_offset=$partition_offset
				source_size=$partition_size
				break
				;;
			ext4|xfs)
				if [[ -z $fallback_offset ]]; then
					fallback_offset=$partition_offset
					fallback_size=$partition_size
				fi
				;;
		esac
	done < <(partx -s -g -o NR,START,SECTORS,TYPE "$source_raw")
	if [[ -z $source_partition && -n $fallback_offset ]]; then
		source_partition=$source_raw
		source_offset=$fallback_offset
		source_size=$fallback_size
	fi
	if [[ -z $source_partition ]]; then
		source_partition=$(lsblk -lnpo NAME,FSTYPE "$source_loop" | awk '$2 == "ext4" || $2 == "xfs" { print $1; exit }')
	fi
fi
[[ -n $source_partition ]] || fail "unable to find Fedora root filesystem partition"
mkdir -p "$source_mount" "$rootfs"
if [[ -n $source_offset ]]; then
	# Release the whole-disk loop before creating the partition-scoped loop;
	# mount(8) rejects overlapping loop devices for the same backing file.
	losetup -d "$source_loop"; source_loop=
	source_partition_loop=$(losetup --find --show --read-only \
		--offset "$source_offset" --sizelimit "$source_size" "$source_partition")
	mount -o ro,subvol=root "$source_partition_loop" "$source_mount"
elif ! mount -o ro "$source_partition" "$source_mount"; then
	# Some Fedora Workstation images expose the root filesystem as a Btrfs
	# subvolume and reject a plain mount of the partition.
	mount -o ro,subvol=root "$source_partition" "$source_mount"
fi
source_mounted=1
if [[ -z $source_offset && ! -f "$source_mount/usr/lib/os-release" ]] &&
	findmnt -n -T "$source_mount" -o FSTYPE | grep -qx btrfs; then
	umount "$source_mount"
	mount -o ro,subvol=root "$source_partition" "$source_mount"
fi
[[ -f "$source_mount/usr/lib/os-release" ]] || fail "Fedora source has no os-release"
grep -q '^ID=fedora$' "$source_mount/usr/lib/os-release" || fail "source is not Fedora"
rsync -aHAX --numeric-ids "$source_mount/" "$rootfs/"
umount "$source_mount"; source_mounted=0
if [[ -n $source_loop ]]; then
	losetup -d "$source_loop"; source_loop=
fi
if [[ -n $source_partition_loop ]]; then
	losetup -d "$source_partition_loop"; source_partition_loop=
fi

resolver_saved=0
if [[ -e $rootfs/etc/resolv.conf || -L $rootfs/etc/resolv.conf ]]; then
	cp -a --no-dereference "$rootfs/etc/resolv.conf" "$work_dir/resolv.conf.original"; resolver_saved=1
fi
rm -f -- "$rootfs/etc/resolv.conf"; cp -L -- /etc/resolv.conf "$rootfs/etc/resolv.conf"

# Keep API mounts private so package hooks cannot affect the host namespace.
mount --bind "$rootfs" "$rootfs"; mount --make-private "$rootfs"; rootfs_mounted=1
for api in dev proc sys; do mount --rbind "/$api" "$rootfs/$api"; mount --make-rslave "$rootfs/$api"; done
mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$rootfs/run"; mount --make-private "$rootfs/run"
if [[ -n $qemu_static ]]; then install -D -m 0755 "$qemu_static" "$rootfs/usr/bin/qemu-aarch64-static"; fi
chroot "$rootfs" /usr/bin/true || fail "AArch64 chroot unavailable; use an AArch64 host or qemu-user-static"
chroot_env=(/usr/bin/env -i HOME=/root LANG=C PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin SYSTEMD_OFFLINE=1)
for variable in http_proxy https_proxy no_proxy; do [[ -n ${!variable:-} ]] && chroot_env+=("$variable=${!variable}"); done

echo "installing Fedora packages and Caihong prerequisites"
chroot "$rootfs" "${chroot_env[@]}" dnf5 -y install --setopt=install_weak_deps=False \
	dnf5-plugins selinux-policy-targeted policycoreutils policycoreutils-python-utils \
	NetworkManager bluez bluez-tools dnsmasq e2fsprogs hostapd iio-sensor-proxy \
	libqmi libqrtr-glib protobuf-c openssh-server alsa-utils

# Enable Copr before any libcamera package enters the image, so the solver
# cannot first install Fedora's implementation and leave a mixed transaction.
if ! chroot "$rootfs" "${chroot_env[@]}" dnf5 copr enable --assumeyes "$copr_repo"; then
	mkdir -p "$rootfs/etc/yum.repos.d"
	base_url="https://download.copr.fedorainfracloud.org/results/$copr_repo/fedora-44-aarch64"
	printf '%s\n' \
	"[$copr_repo_id]" \
	"name=Caihong Copr ($copr_repo)" "baseurl=$base_url/" "enabled=1" \
	"gpgcheck=1" "gpgkey=$base_url/repodata/repomd.xml.key" \
	> "$rootfs/etc/yum.repos.d/caihong-copr.repo"
fi

# Keep the device integration that is not packaged in Copr.  The Copr
# transaction below runs after this overlay, so paths owned by an RPM use the
# packaged implementation rather than a stale local duplicate.
echo "overlaying Caihong userspace"
rsync -aHAX --numeric-ids --chown=0:0 "$project_dir/rootfs/caihong/" "$rootfs/"
if [[ -x $rootfs/usr/sbin/resize2fs ]]; then
	sed -i 's#/usr/bin/resize2fs#/usr/sbin/resize2fs#' "$rootfs/etc/systemd/system/caihong-grow-rootfs.service"
fi

# Install every binary package published in the Copr, not a fixed list, so a
# package added to the Copr reaches the next image without editing this
# script.  The Fedora Workstation source image already contains Fedora builds
# of some of these names (libcamera, ffmpeg-free libraries), so the exact Copr
# builds are installed with rpm: --oldpackage replaces a newer Fedora EVR and
# --replacefiles is required because the device packages intentionally own a
# few files also shipped by Fedora (for example /etc/bluetooth/main.conf).
copr_setopt=(--setopt="$copr_repo_id.priority=$copr_priority")
copr_list=$work_dir/copr-packages
chroot "$rootfs" "${chroot_env[@]}" dnf5 repoquery --refresh --quiet "${copr_setopt[@]}" \
	--repo="$copr_repo_id" --latest-limit=1 --arch=aarch64,noarch \
	--queryformat='%{name} %{epoch}:%{version}-%{release}\n' > "$copr_list.all"
awk 'NF == 2' "$copr_list.all" | sort -u > "$copr_list.sorted"
if [[ -n $copr_exclude_regex ]]; then
	awk '{ print $1 }' "$copr_list.sorted" | grep -Ev -- "$copr_exclude_regex" > "$copr_list.names" || true
else
	awk '{ print $1 }' "$copr_list.sorted" > "$copr_list.names"
fi
mapfile -t copr_packages < "$copr_list.names"
(( ${#copr_packages[@]} > 0 )) || fail "Copr $copr_repo lists no installable packages"
for package in caihong-device-support caihong-firmware caihong-kernel-updater caihong-ssc libcamera; do
	grep -qx -- "$package" "$copr_list.names" || fail "Copr $copr_repo does not provide $package"
done
package=
if [[ -n $copr_exclude_regex ]]; then
	skipped=$(awk '{ print $1 }' "$copr_list.sorted" | grep -E -- "$copr_exclude_regex" | tr '\n' ' ' || true)
else
	skipped=
fi
echo "installing ${#copr_packages[@]} Copr packages: ${copr_packages[*]}"
[[ -z $skipped ]] || echo "skipping Copr packages matching $copr_exclude_regex: $skipped"

rpm_stage=/tmp/caihong-copr-rpms
copr_key_stage=/tmp/caihong-copr-key.gpg
curl --fail --location --retry 4 \
	--output "$rootfs$copr_key_stage" \
	"https://download.copr.fedorainfracloud.org/results/$copr_repo/pubkey.gpg"
chroot "$rootfs" "${chroot_env[@]}" rpm --import "$copr_key_stage"
rm -rf -- "$rootfs$rpm_stage"
install -d -m 0755 "$rootfs$rpm_stage"
chroot "$rootfs" "${chroot_env[@]}" dnf5 download --resolve "${copr_setopt[@]}" \
	--from-repo="$copr_repo_id" --destdir="$rpm_stage" "${copr_packages[@]}"
mapfile -t downloaded_rpms < <(find "$rootfs$rpm_stage" -mindepth 1 -maxdepth 1 -type f -name '*.rpm' -printf '%f\n')
(( ${#downloaded_rpms[@]} > 0 )) || fail "Copr download produced no RPMs"
rpm_args=()
for rpm_file in "${downloaded_rpms[@]}"; do
	# dnf5 download may include source RPMs when resolving a Copr package;
	# they are not installable rootfs content and must not shadow the binary.
	[[ $rpm_file == *.src.rpm ]] && continue
	rpm_args+=("$rpm_stage/$rpm_file")
done
chroot "$rootfs" "${chroot_env[@]}" rpm -U --replacefiles --replacepkgs --oldpackage "${rpm_args[@]}"
rm -rf -- "$rootfs$rpm_stage" "$rootfs$copr_key_stage"

# Every Copr package must now be installed in exactly the Copr EVR.
copr_installed=$work_dir/copr-installed
: > "$copr_installed"
while read -r package package_evr; do
	grep -qx -- "$package" "$copr_list.names" || continue
	installed_evr=$(chroot "$rootfs" rpm -q --qf '%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n' "$package" </dev/null) ||
		fail "Copr package $package is not installed"
	[[ $installed_evr == "$package_evr" ]] ||
		fail "$package is $installed_evr, expected the Copr build $package_evr"
	printf 'copr_package=%s %s\n' "$package" "$package_evr" >> "$copr_installed"
done < "$copr_list.sorted"
package=
[[ -f "$rootfs/etc/dnf/repos.override.d/90-caihong-copr.repo" ]] ||
	fail "caihong-device-support did not install the Copr priority override"
chroot "$rootfs" "${chroot_env[@]}" dnf5 clean all

echo "installing matching kernel modules"
rm -rf -- "$rootfs/usr/lib/modules"
CAIHONG_EXPECTED_RELEASE="$kernel_release" \
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$rootfs"
pen_module=$(find "$rootfs/usr/lib/modules/$kernel_release" -name caihong_pen_power.ko -print -quit)
[[ -n $pen_module ]] || fail "installed module tree has no caihong_pen_power.ko"
install -D -m 0644 "$pen_module" "$rootfs/usr/local/lib/caihong/caihong_pen_power.ko"

echo "installing kernel and boot metadata"
install -d -m 0755 "$rootfs/usr/lib/linux-caihong"
install -m 0644 "$release_dir/Image-$kernel_release" "$rootfs/usr/lib/linux-caihong/Image"
install -m 0644 "$release_dir/sm8650-oneplus-caihong-$kernel_release.dtb" "$rootfs/usr/lib/linux-caihong/caihong.dtb"
install -m 0644 "$release_dir/caihong-boot-linux-$kernel_release.img" "$rootfs/usr/lib/linux-caihong/boot-linux.img"
install -m 0644 "$release_dir/caihong-boot-userdata-$kernel_release.img" "$rootfs/usr/lib/linux-caihong/boot-userdata.img"
printf '%s\n' "$kernel_release" > "$rootfs/usr/lib/linux-caihong/kernel-release"

echo "configuring Fedora SELinux and systemd"
selinux_config="$rootfs/etc/selinux/config"
if [[ -f $selinux_config ]]; then
	sed -i -E "s/^SELINUX=.*/SELINUX=$selinux_mode/; s/^SELINUXTYPE=.*/SELINUXTYPE=targeted/" "$selinux_config"
	grep -q '^SELINUX=' "$selinux_config" || printf 'SELINUX=%s\n' "$selinux_mode" >> "$selinux_config"
	grep -q '^SELINUXTYPE=' "$selinux_config" || printf 'SELINUXTYPE=targeted\n' >> "$selinux_config"
else
	install -D -m 0644 /dev/null "$selinux_config"
	printf 'SELINUX=%s\nSELINUXTYPE=targeted\n' "$selinux_mode" > "$selinux_config"
fi
touch "$rootfs/.autorelabel"
systemctl --root="$rootfs" enable NetworkManager.service bluetooth.service sshd.service \
	iio-sensor-proxy.service caihong-ssc.service caihong-grow-rootfs.service caihong-bluetooth-autostart.service \
	caihong-hardware-mac.service caihong-mark-boot-successful.service caihong-hotspot.service \
	caihong-pen-autoconnect.timer caihong-pen-charge.timer caihong-pen-pair.timer \
	caihong-kernel-install.service 2>/dev/null || true
systemctl --root="$rootfs" set-default graphical.target
cat > "$rootfs/etc/fstab" <<'EOF'
LABEL=linux / ext4 rw,noatime 0 1
EOF
printf 'caihong\n' > "$rootfs/etc/hostname"
printf 'LANG=en_US.UTF-8\n' > "$rootfs/etc/locale.conf"

rm -f -- "$rootfs/usr/bin/qemu-aarch64-static" "$rootfs/etc/resolv.conf"
if (( resolver_saved )); then cp -a --no-dereference "$work_dir/resolv.conf.original" "$rootfs/etc/resolv.conf"; fi
for api in dev proc sys run; do umount --lazy "$rootfs/$api"; done
umount --lazy "$rootfs"; rootfs_mounted=0

printf 'device=caihong\narchitecture=aarch64\ndistribution=fedora\nfedora_release=44\n' > "$rootfs/etc/caihong-rootfs-build-info"
printf 'copr=%s\nselinux_mode=%s\nkernel_release=%s\n' "$copr_repo" "$selinux_mode" "$kernel_release" >> "$rootfs/etc/caihong-rootfs-build-info"
cat "$copr_installed" >> "$rootfs/etc/caihong-rootfs-build-info"
chmod 0644 "$rootfs/etc/caihong-rootfs-build-info"
rm -f -- "$rootfs/etc/machine-id"; : > "$rootfs/etc/machine-id"
"$project_dir/scripts/verify-fedora-rootfs.sh" "$rootfs"

used_bytes=$(du -sx --block-size=1 "$rootfs" | awk 'NR == 1 { print $1 }')
percent_free=$((used_bytes * image_slack_percent / 100)); minimum_free=$((image_min_free_mib * 1024 * 1024))
free_bytes=$((percent_free > minimum_free ? percent_free : minimum_free)); required_bytes=$((used_bytes + free_bytes))
round_bytes=$((256 * 1024 * 1024)); image_bytes=$(((required_bytes + round_bytes - 1) / round_bytes * round_bytes))
mkdir -p "$image_mount"; truncate -s "$image_bytes" "$raw_image"
mkfs.ext4 -q -F -L linux -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$raw_image"
mount -o loop "$raw_image" "$image_mount"; image_mounted=1
rsync -aHAX --numeric-ids "$rootfs/" "$image_mount/"; sync -f "$image_mount"
umount "$image_mount"; image_mounted=0; e2fsck -fn "$raw_image"
[[ $(blkid -s LABEL -o value "$raw_image") == linux ]] || fail "wrong ext4 label"
if (( sparse_image )); then img2simg "$raw_image" "$temporary"; else mv "$raw_image" "$temporary"; fi
mv -- "$temporary" "$output"
echo "created Fedora rootfs: $output"; du -h "$output"; sha256sum "$output"
