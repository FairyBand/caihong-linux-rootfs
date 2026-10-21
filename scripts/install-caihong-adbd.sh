#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
target=${1:-}
if [ -z "$target" ] || [ ! -d "$target" ]; then
	echo "usage: $0 ROOTFS_DIR" >&2
	exit 2
fi
target=$(cd -- "$target" && pwd)

cache=${CAIHONG_ADBD_CACHE:-"$project_dir/downloads/caihong-adbd"}
mkdir -p "$cache"

android_base=https://deb.debian.org/debian/pool/main/a/android-platform-tools
boringssl_base=https://deb.debian.org/debian/pool/main/a/android-platform-external-boringssl
protobuf_base=https://deb.debian.org/debian/pool/main/p/protobuf

packages='
adbd_34.0.5-13_arm64.deb 502357a4ba2beea0412dee705219dca855c705cbde4307a0d03efdeb2a2fbbca ANDROID
android-libbase_34.0.5-13_arm64.deb eda3383b0948e9d83c05de2580b9e7abc91043f5a5eda720ac78613de91eff69 ANDROID
android-libcutils_34.0.5-13_arm64.deb bc080151a31ae569634e64101fe8769c4e142a12dbdcc28f41e7c437fb2b6c36 ANDROID
android-liblog_34.0.5-13_arm64.deb 891458f051560a51d2e3b0458b8437529d05b4f216ed4350b821dbbfcb86e4b1 ANDROID
android-libboringssl_14.0.0+r45-3+b2_arm64.deb d91e99628c49781f53277a5ba06ae3e6f7b1d5b1bb46661762bb7fd3ee7edf64 BORINGSSL
libprotobuf32t64_3.21.12-11+deb13u1_arm64.deb 51bf38fcca667be0deef732a903563ee6ffa9bfc04433310c2c49e4c92d06b09 PROTOBUF
'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/caihong-adbd.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

fetch()
{
	name=$1
	hash=$2
	source=$3
	path=$cache/$name
	if [ ! -f "$path" ] || [ "$(sha256sum "$path" | awk '{ print $1 }')" != "$hash" ]; then
		rm -f -- "$path"
		case "$source" in
			ANDROID) base=$android_base ;;
			BORINGSSL) base=$boringssl_base ;;
			PROTOBUF) base=$protobuf_base ;;
			*) echo "unknown package source: $source" >&2; exit 1 ;;
		esac
		curl -fsSL --retry 4 --retry-delay 2 -o "$path" "$base/$name"
	fi
	actual=$(sha256sum "$path" | awk '{ print $1 }')
	[ "$actual" = "$hash" ] || {
		echo "checksum mismatch for $name" >&2
		exit 1
	}
}

extract()
{
	name=$1
	dir=$work_dir/${name%.deb}
	mkdir -p "$dir"
	bsdtar -xOf "$cache/$name" data.tar.xz | tar -xJf - -C "$dir"
}

printf '%s\n' "$packages" | while read -r name hash source; do
	[ -n "$name" ] || continue
	fetch "$name" "$hash" "$source"
	extract "$name"
done

adbd_source=$work_dir/adbd_34.0.5-13_arm64/usr/lib/android-sdk/platform-tools/adbd
[ -x "$adbd_source" ] || {
	echo "Debian adbd payload is missing" >&2
	exit 1
}

install -D -m 0755 "$adbd_source" "$target/usr/bin/adbd"
install -d -m 0755 "$target/usr/lib/caihong-adbd" \
	"$target/usr/share/licenses/caihong-adbd"

for library in \
	android-libbase_34.0.5-13_arm64/usr/lib/aarch64-linux-gnu/android/libbase.so.0 \
	android-libcutils_34.0.5-13_arm64/usr/lib/aarch64-linux-gnu/android/libcutils.so.0 \
	android-liblog_34.0.5-13_arm64/usr/lib/aarch64-linux-gnu/android/liblog.so.0 \
	android-libboringssl_14.0.0+r45-3+b2_arm64/usr/lib/aarch64-linux-gnu/android/libcrypto.so.0 \
	android-libboringssl_14.0.0+r45-3+b2_arm64/usr/lib/aarch64-linux-gnu/android/libssl.so.0 \
	libprotobuf32t64_3.21.12-11+deb13u1_arm64/usr/lib/aarch64-linux-gnu/libprotobuf.so.32.0.12; do
	source_file=$work_dir/$library
	[ -f "$source_file" ] || {
		echo "Debian adbd library is missing: ${library##*/}" >&2
		exit 1
	}
	install -m 0644 "$source_file" "$target/usr/lib/caihong-adbd/${library##*/}"
done
ln -sfn libprotobuf.so.32.0.12 \
	"$target/usr/lib/caihong-adbd/libprotobuf.so.32"

for package in adbd android-libbase android-libcutils android-liblog \
	android-libboringssl libprotobuf32t64; do
	dir=$(find "$work_dir" -maxdepth 1 -type d -name "$package*" -print -quit)
	[ -n "$dir" ] || continue
	copyright=$dir/usr/share/doc/$package/copyright
	[ -f "$copyright" ] || continue
	install -D -m 0644 "$copyright" \
		"$target/usr/share/licenses/caihong-adbd/$package-copyright"
done
install -D -m 0644 \
	"$work_dir/adbd_34.0.5-13_arm64/usr/share/doc/adbd/NOTICE.gz" \
	"$target/usr/share/licenses/caihong-adbd/AOSP-NOTICE.gz"

cat > "$target/usr/lib/caihong-adbd/runtime" <<'EOF'
adbd=34.0.5-13
android-libbase=34.0.5-13
android-libcutils=34.0.5-13
android-liblog=34.0.5-13
android-libboringssl=14.0.0+r45-3+b2
libprotobuf32t64=3.21.12-11+deb13u1
source=https://deb.debian.org/debian
EOF
chmod 0644 "$target/usr/lib/caihong-adbd/runtime"

echo "installed Caihong ADB daemon runtime into $target"
