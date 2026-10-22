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
	qnn/bin/caihong-npu-htp-self-test \
	qnn/bin/caihong-npu-htp-conv-test \
	qnn/lib/libQnnHtp.so \
	qnn/lib/libQnnHtpPrepare.so \
	qnn/lib/libQnnHtpV75Stub.so \
	dsp/v75/libcalculator_skel.so \
	dsp/v75/libQnnHtpV75Skel.so \
	dsp/v75/libc++.so.1 \
	dsp/v75/libc++abi.so.1 \
	dsp/v75/fastrpc_shell_unsigned_3 \
	qnn/LICENSE.geniex-qairt-plugin qnn/THIRD_PARTY_NOTICES.md \
	LICENSE.fastrpc SOURCE.md VERSION; do
	[[ -f $bundle/$input ]] || fail "bundle is missing $input"
done

file "$bundle/lib/libcdsprpc.so.1.0.0" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "libcdsprpc is not AArch64"
file "$bundle/lib/libcalculator.so" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "calculator stub is not AArch64"
file "$bundle/qnn/bin/caihong-npu-htp-self-test" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "HTP self-test is not AArch64"
file "$bundle/qnn/bin/caihong-npu-htp-conv-test" |
	grep -q 'ELF 64-bit.*ARM aarch64' || fail "HTP Conv2d self-test is not AArch64"
for input in libQnnHtp.so libQnnHtpPrepare.so libQnnHtpV75Stub.so; do
	file "$bundle/qnn/lib/$input" |
		grep -q 'ELF 64-bit.*ARM aarch64' || fail "$input is not AArch64"
done
file "$bundle/dsp/v75/libcalculator_skel.so" |
	grep -q 'QUALCOMM DSP6' || fail "calculator skel is not Hexagon DSP code"
for input in libQnnHtpV75Skel.so libc++.so.1 libc++abi.so.1; do
	file "$bundle/dsp/v75/$input" |
		grep -q 'QUALCOMM DSP6' || fail "$input is not Hexagon DSP code"
done
file "$bundle/dsp/v75/fastrpc_shell_unsigned_3" |
	grep -q 'QUALCOMM DSP6' || fail "unsigned PD shell is not Hexagon DSP code"

install -D -m 0755 "$bundle/lib/libcdsprpc.so.1.0.0" \
	"$rootfs/usr/$libdir/libcdsprpc.so.1.0.0"
ln -sfn libcdsprpc.so.1.0.0 "$rootfs/usr/$libdir/libcdsprpc.so.1"
ln -sfn libcdsprpc.so.1.0.0 "$rootfs/usr/$libdir/libcdsprpc.so"
install -D -m 0755 "$bundle/lib/libcalculator.so" \
	"$rootfs/usr/$libdir/caihong-npu/libcalculator.so"
install -D -m 0755 "$bundle/qnn/bin/caihong-npu-htp-self-test" \
	"$rootfs/usr/local/libexec/caihong-npu-htp-self-test"
install -D -m 0755 "$bundle/qnn/bin/caihong-npu-htp-conv-test" \
	"$rootfs/usr/local/libexec/caihong-npu-htp-conv-test"
for input in libQnnHtp.so libQnnHtpPrepare.so libQnnHtpV75Stub.so; do
	install -D -m 0755 "$bundle/qnn/lib/$input" \
		"$rootfs/usr/$libdir/caihong-npu/qnn/$input"
	ln -sfn "caihong-npu/qnn/$input" "$rootfs/usr/$libdir/$input"
done
install -D -m 0644 "$bundle/dsp/v75/libcalculator_skel.so" \
	"$rootfs/usr/share/caihong-npu/dsp/v75/libcalculator_skel.so"
for input in libQnnHtpV75Skel.so libc++.so.1 libc++abi.so.1; do
	install -D -m 0644 "$bundle/dsp/v75/$input" \
		"$rootfs/usr/share/caihong-npu/dsp/v75/$input"
done
install -D -m 0644 "$bundle/dsp/v75/fastrpc_shell_unsigned_3" \
	"$rootfs/usr/share/caihong-npu/dsp/v75/fastrpc_shell_unsigned_3"
install -d -m 0755 "$rootfs/usr/lib/dsp"
for input in \
	fastrpc_shell_unsigned_3 \
	libcalculator_skel.so \
	libQnnHtpV75Skel.so \
	libc++.so.1 \
	libc++abi.so.1; do
	ln -sfn "../../share/caihong-npu/dsp/v75/$input" \
		"$rootfs/usr/lib/dsp/$input"
done
install -d -m 0755 "$rootfs/usr/lib/udev/rules.d"
cat > "$rootfs/usr/lib/udev/rules.d/99-caihong-fastrpc.rules" <<'EOF'
SUBSYSTEM=="misc", KERNEL=="fastrpc-cdsp", GROUP="render", MODE="0660", TAG+="uaccess"
EOF
chmod 0644 "$rootfs/usr/lib/udev/rules.d/99-caihong-fastrpc.rules"
install -D -m 0644 "$bundle/LICENSE.fastrpc" \
	"$rootfs/usr/share/licenses/caihong-npu/LICENSE.fastrpc"
install -D -m 0644 "$bundle/qnn/LICENSE.geniex-qairt-plugin" \
	"$rootfs/usr/share/licenses/caihong-npu/LICENSE.geniex-qairt-plugin"
install -D -m 0644 "$bundle/qnn/THIRD_PARTY_NOTICES.md" \
	"$rootfs/usr/share/licenses/caihong-npu/THIRD_PARTY_NOTICES.QAIRT.md"
install -D -m 0644 "$bundle/SOURCE.md" \
	"$rootfs/usr/share/doc/caihong-npu/SOURCE.md"
install -D -m 0644 "$bundle/VERSION" \
	"$rootfs/usr/share/caihong-npu/VERSION"
