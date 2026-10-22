#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 fairyband <zl3004431@gmail.com>
#
# Assemble the release archive that caihong-kernel-payload.spec builds from.
# The kernel build and the Android boot images are produced here, not by Copr,
# so the payload is handed over as a single source archive: Image, the DTB,
# both boot images, the module tree and a kernel-release marker.
#
# The archive name carries the kernel release, and the spec turns that into the
# package Version, so an in-flight dnf transaction can never mix a new module
# tree with an old boot image.
set -eu
CDPATH=

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(cd -- "$script_dir/.." && pwd)

module_tree=${MODULE_TREE:-"$project_dir/modules-current"}
release_dir=${RELEASE_DIR:-"$project_dir/release"}
output_dir=${1:-"$release_dir"}

for tool in cpio find sha256sum tar zstd; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "missing tool: $tool" >&2
		exit 1
	}
done

[ -d "$module_tree" ] || { echo "missing module tree: $module_tree" >&2; exit 1; }
[ -f "$release_dir/KERNEL_RELEASE" ] || {
	echo "missing $release_dir/KERNEL_RELEASE" >&2
	exit 1
}
release=$(cat "$release_dir/KERNEL_RELEASE")
[ -n "$release" ] || { echo "empty kernel release" >&2; exit 1; }

# One release per archive: a stale leftover tree from an earlier build would
# otherwise be shipped next to the current modules.
module_releases=
module_count=0
for candidate in "$module_tree"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	module_releases="$module_releases ${candidate##*/}"
	module_count=$((module_count + 1))
done
[ "$module_count" -ge 1 ] || { echo "module tree is empty" >&2; exit 1; }
[ "$module_count" -eq 1 ] || {
	echo "module tree holds several releases:$module_releases" >&2
	exit 1
}
[ "$module_releases" = " $release" ] || {
	echo "module tree holds '$module_releases' but KERNEL_RELEASE is '$release'" >&2
	exit 1
}

image=$(find "$release_dir" -maxdepth 1 -type f -name "Image-$release" -print -quit)
[ -n "$image" ] || { echo "missing Image-$release" >&2; exit 1; }

dtb=$(find "$release_dir" -maxdepth 1 -type f \
	-name "*-caihong-$release.dtb" -print -quit)
[ -n "$dtb" ] || { echo "missing the caihong DTB for $release" >&2; exit 1; }

boot_linux="$release_dir/caihong-boot-linux-$release.img"
boot_userdata="$release_dir/caihong-boot-userdata-$release.img"
for input in "$boot_linux" "$boot_userdata"; do
	[ -f "$input" ] || { echo "missing package input: $input" >&2; exit 1; }
done

# rpm rejects a version segment with a dash or an underscore, and the module
# tree uses both.  Keep the mapping in one place so the spec and this script
# cannot disagree about the package version.
pkgver=$(printf '%s' "$release" | sed 's/[^[:alnum:].+]/_/g')

archive=caihong-kernel-payload-$pkgver.tar.zst
output=$output_dir/$archive
temporary=$output.new
stage=$(mktemp -d "${TMPDIR:-/tmp}/caihong-kernel-payload.XXXXXX")

cleanup()
{
	rm -rf -- "$stage"
	rm -f -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

install -m 0644 "$image" "$stage/Image"
install -m 0644 "$dtb" "$stage/caihong.dtb"
install -m 0644 "$boot_linux" "$stage/boot-linux.img"
install -m 0644 "$boot_userdata" "$stage/boot-userdata.img"
printf '%s\n' "$release" > "$stage/kernel-release"
install -m 0644 "$project_dir/linux/COPYING" "$stage/LICENSE"

install -d -m 0755 "$stage/modules"
# Copy instead of hard-linking: the staging directory may live on a different
# filesystem than the build tree, and hard links across devices fail.
cp -a -- "$module_tree/lib/modules/$release" "$stage/modules/$release"

# Reproducible ordering and ownership: Copr builds the same bytes for the same
# input, which keeps a rebuild from looking like a new package.
find "$stage" -print0 | LC_ALL=C sort -z |
	xargs -0 -- touch -h -d "@${SOURCE_DATE_EPOCH:-0}"

mkdir -p "$output_dir"
rm -f -- "$temporary"
tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@${SOURCE_DATE_EPOCH:-0}" \
	-C "$stage" -cf - . |
	zstd -T"$(nproc)" -15 -o "$temporary"
mv -- "$temporary" "$output"

# Read the archive back rather than trusting the staging directory: the payload
# is what boots the device, so a truncated or mis-tarred archive must not reach
# Copr.
listing=$(tar --zstd -tf "$output")
for member in Image caihong.dtb boot-linux.img boot-userdata.img \
	kernel-release LICENSE "modules/$release"; do
	# tar lists directories with a trailing slash, so accept both spellings.
	printf '%s\n' "$listing" | grep -qx "\./$member/\?" || {
		echo "payload archive is missing $member" >&2
		exit 1
	}
done
extracted=$(mktemp -d "${TMPDIR:-/tmp}/caihong-kernel-payload-check.XXXXXX")
trap 'rm -rf -- "$stage" "$extracted"; rm -f -- "$temporary"' EXIT HUP INT TERM
tar --zstd -xf "$output" -C "$extracted"
for member in Image caihong.dtb boot-linux.img boot-userdata.img kernel-release; do
	cmp "$stage/$member" "$extracted/$member" || {
		echo "payload member $member does not round-trip" >&2
		exit 1
	}
done
[ "$(cat "$extracted/kernel-release")" = "$release" ] || {
	echo "kernel-release round-trip mismatch" >&2
	exit 1
}
test -d "$extracted/modules/$release" || {
	echo "module tree is missing from the payload archive" >&2
	exit 1
}
for member in Image caihong.dtb boot-linux.img boot-userdata.img; do
	[ -s "$extracted/$member" ] || {
		echo "payload member $member is empty" >&2
		exit 1
	}
done

rm -rf -- "$stage" "$extracted"
trap - EXIT HUP INT TERM
printf '%s\n' "$archive" > "$release_dir/KERNEL_PAYLOAD"
echo "created payload archive: $output"
sha256sum "$output"