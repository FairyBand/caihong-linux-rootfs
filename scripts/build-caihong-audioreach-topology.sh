#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_dir=${AUDIOREACH_TOPOLOGY_DIR:-"$project_dir/external/audioreach-topology"}
output=${1:-"$project_dir/build/audioreach-topology/qcom/sm8650/SM8650-MTP-tplg.bin"}
template="$source_dir/SM8650-Caihong.m4"

if [ ! -f "$template" ]; then
	echo "missing official AudioReach topology source: $template" >&2
	exit 1
fi

alsatplg=${ALSATPLG:-}
if [ -z "$alsatplg" ]; then
	alsatplg=$(command -v alsatplg || true)
fi
if [ -z "$alsatplg" ] && [ -x "$project_dir/build/tools/alsa-utils/usr/bin/alsatplg" ]; then
	alsatplg="$project_dir/build/tools/alsa-utils/usr/bin/alsatplg"
fi
if [ -z "$alsatplg" ] || [ ! -x "$alsatplg" ]; then
	echo "alsatplg is required (set ALSATPLG or install alsa-utils)" >&2
	exit 1
fi

work_parent="$project_dir/build"
mkdir -p "$work_parent" "$(dirname -- "$output")"
work_dir=$(mktemp -d "$work_parent/caihong-audioreach.XXXXXX")
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

config="$work_dir/SM8650-MTP.conf"
m4 -I "$work_dir" -I "$source_dir" "$template" > "$config"
"$alsatplg" -c "$config" -o "$output"

echo "built $output from Caihong AudioReach topology"
sha256sum "$output"
