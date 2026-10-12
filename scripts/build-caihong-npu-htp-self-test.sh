#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
include_dir=${QNN_INCLUDE_DIR:-}
cc=${CC:-aarch64-linux-gnu-gcc}
output=${1:-"$project_dir/firmware-assets/caihong-npu/qnn/bin/caihong-npu-htp-self-test"}

if [[ -z $include_dir || ! -f $include_dir/QnnInterface.h ]]; then
	echo "set QNN_INCLUDE_DIR to the QAIRT QNN include directory" >&2
	exit 1
fi

mkdir -p -- "$(dirname -- "$output")"
"$cc" -std=gnu11 -O2 -Wall -Wextra -Werror \
	-I "$include_dir" \
	-o "$output" "$project_dir/tools/caihong-npu-htp-self-test.c" \
	-ldl -lm
file "$output" | grep -q 'ELF 64-bit.*ARM aarch64' || {
	echo "HTP self-test is not AArch64: $output" >&2
	exit 1
}
sha256sum "$output"
