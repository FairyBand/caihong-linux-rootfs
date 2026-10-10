#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
module_tree=${1:-"$project_dir/modules-current"}
release_dir=${2:-"$project_dir/release"}

for tool in bsdtar depmod nproc sha256sum zstd; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing tool: $tool" >&2
		exit 1
	}
done

cpu_count=$(nproc)
if [ "$cpu_count" -gt 1 ]; then
	zstd_threads=$((cpu_count - 1))
else
	zstd_threads=1
fi
zstd_threads=${ZSTD_THREADS:-$zstd_threads}

release=
for candidate in "$module_tree"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	[ -z "$release" ] || {
		echo "module tree contains more than one kernel release" >&2
		exit 1
	}
	release=${candidate##*/}
done
[ -n "$release" ] || { echo "module tree contains no kernel release" >&2; exit 1; }

boot_linux="$release_dir/caihong-boot-linux-$release.img"
boot_userdata="$release_dir/caihong-boot-userdata-$release.img"
for input in "$boot_linux" "$boot_userdata"; do
	[ -f "$input" ] || { echo "missing package input: $input" >&2; exit 1; }
done

pkgver=$(printf '%s' "$release" | sed 's/[^[:alnum:].+]/./g')
pkgrel=1
package_name="linux-caihong-$pkgver-$pkgrel-aarch64.pkg.tar.zst"
output="$release_dir/$package_name"
temporary="$output.new"
stage=$(mktemp -d "${TMPDIR:-/tmp}/linux-caihong-package.XXXXXX")

cleanup()
{
	rm -rf -- "$stage"
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

module_stage="$stage/module-stage"
CAIHONG_EXPECTED_RELEASE=$release \
	"$project_dir/scripts/install-caihong-modules.sh" "$module_tree" "$module_stage"
install -d -m 0755 "$stage/usr/lib/linux-caihong/modules"
mv -- "$module_stage/lib/modules/$release" \
	"$stage/usr/lib/linux-caihong/modules/$release"
rm -rf -- "$module_stage"
install -D -m 0644 "$project_dir/rootfs/archlinuxarm/etc/modules-load.d/caihong.conf" \
	"$stage/usr/lib/modules-load.d/caihong.conf"
install -D -m 0755 \
	"$project_dir/packaging/linux-caihong/install-current-slot" \
	"$stage/usr/lib/linux-caihong/install-current-slot"
install -m 0644 "$boot_linux" "$stage/usr/lib/linux-caihong/boot-linux.img"
install -m 0644 "$boot_userdata" "$stage/usr/lib/linux-caihong/boot-userdata.img"
printf '%s\n' "$release" > "$stage/usr/lib/linux-caihong/kernel-release"
install -D -m 0644 "$project_dir/linux/COPYING" \
	"$stage/usr/share/licenses/linux-caihong/COPYING"
install -m 0644 "$project_dir/packaging/linux-caihong/linux-caihong.install" \
	"$stage/.INSTALL"

installed_size=$(du -sb "$stage" | awk '{ print $1 }')
builddate=${SOURCE_DATE_EPOCH:-$(date +%s)}
cat > "$stage/.PKGINFO" <<EOF
pkgname = linux-caihong
pkgbase = linux-caihong
pkgver = $pkgver-$pkgrel
pkgdesc = Mainline Linux kernel and modules for OnePlus Pad Pro (caihong)
url = https://github.com/Osilvfe/linux
builddate = $builddate
packager = Osilvfe <osilvfe@gmail.com>
size = $installed_size
arch = aarch64
license = GPL-2.0-only
depend = bash
depend = coreutils
depend = findutils
depend = grep
depend = kmod
depend = util-linux
EOF

mkdir -p "$release_dir"
rm -f -- "$temporary"
bsdtar --uid 0 --gid 0 --uname root --gname root -cf - -C "$stage" \
	.PKGINFO .INSTALL usr \
	| zstd -T"$zstd_threads" -15 -o "$temporary"
mv -- "$temporary" "$output"

pkginfo=$(bsdtar -xOf "$output" .PKGINFO)
printf '%s\n' "$pkginfo" | grep -qx 'pkgname = linux-caihong'
printf '%s\n' "$pkginfo" | grep -qx 'arch = aarch64'
archived_release=$(bsdtar -xOf "$output" \
	usr/lib/linux-caihong/kernel-release)
[ "$archived_release" = "$release" ] || {
	echo "packaged kernel release does not match $release" >&2
	exit 1
}
for root_partlabel in linux userdata; do
	source_hash=$(sha256sum "$release_dir/caihong-boot-$root_partlabel-$release.img" |
		awk '{ print $1 }')
	archive_hash=$(bsdtar -xOf "$output" \
		"usr/lib/linux-caihong/boot-$root_partlabel.img" |
		sha256sum | awk '{ print $1 }')
	[ "$source_hash" = "$archive_hash" ] || {
		echo "packaged $root_partlabel boot image failed verification" >&2
		exit 1
	}
done
if bsdtar -tf "$output" | grep -q '^usr/lib/modules/'; then
	echo "package must not own the activated module directory" >&2
	exit 1
fi

printf '%s\n' "$package_name" > "$release_dir/LINUX_CAIHONG_PACKAGE"
rm -rf -- "$stage"
trap - EXIT HUP INT TERM
echo "created pacman package: $output"
sha256sum "$output"
