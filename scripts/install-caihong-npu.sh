#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

bundle=${1:-}
rootfs=${2:-}
libdir=${3:-lib}

fail()
{
	echo "install-caihong-npu: $*" >&2
	exit 1
}

[[ -d $bundle ]] || fail "bundle directory not found: ${bundle:-unset}"
[[ -d $rootfs ]] || fail "rootfs directory not found: ${rootfs:-unset}"
[[ $libdir == lib || $libdir == lib64 ]] || fail "LIBDIR must be lib or lib64"
[[ -f $bundle/SHA256SUMS ]] || fail "bundle has no SHA256SUMS"
(cd "$bundle" && sha256sum -c SHA256SUMS)

for input in \
	lib/libcdsprpc.so.1.0.0 \
	lib/libcalculator.so \
	dsp/v75/libcalculator_skel.so \
	dsp/v75/fastrpc_shell_unsigned_3 \
	LICENSE.fastrpc SOURCE.md VERSION; do
	[[ -f $bundle/$input ]] || fail "bundle is missing $input"
done

file "$bundle/lib/libcdsprpc.so.1.0.0" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "libcdsprpc is not AArch64"
file "$bundle/lib/libcalculator.so" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "calculator stub is not AArch64"
file "$bundle/dsp/v75/libcalculator_skel.so" |
	grep -q 'QUALCOMM DSP6' || fail "calculator skel is not Hexagon DSP code"
file "$bundle/dsp/v75/fastrpc_shell_unsigned_3" |
	grep -q 'QUALCOMM DSP6' || fail "unsigned PD shell is not Hexagon DSP code"

install -D -m 0755 "$bundle/lib/libcdsprpc.so.1.0.0" \
	"$rootfs/usr/$libdir/libcdsprpc.so.1.0.0"
ln -sfn libcdsprpc.so.1.0.0 "$rootfs/usr/$libdir/libcdsprpc.so.1"
ln -sfn libcdsprpc.so.1.0.0 "$rootfs/usr/$libdir/libcdsprpc.so"
install -D -m 0755 "$bundle/lib/libcalculator.so" \
	"$rootfs/usr/$libdir/caihong-npu/libcalculator.so"
install -D -m 0644 "$bundle/dsp/v75/libcalculator_skel.so" \
	"$rootfs/usr/share/caihong-npu/dsp/v75/libcalculator_skel.so"
install -D -m 0644 "$bundle/dsp/v75/fastrpc_shell_unsigned_3" \
	"$rootfs/usr/share/caihong-npu/dsp/v75/fastrpc_shell_unsigned_3"
install -D -m 0644 "$bundle/LICENSE.fastrpc" \
	"$rootfs/usr/share/licenses/caihong-npu/LICENSE.fastrpc"
install -D -m 0644 "$bundle/SOURCE.md" \
	"$rootfs/usr/share/doc/caihong-npu/SOURCE.md"
install -D -m 0644 "$bundle/VERSION" \
	"$rootfs/usr/share/caihong-npu/VERSION"
