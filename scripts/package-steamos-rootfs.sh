#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=../steamos.env
source "$project_dir/steamos.env"

output=${1:-"$project_dir/caihong-steamos-rootfs.img"}
source_archive=${2:-"$project_dir/downloads/steamos-$STEAMOS_SNAPSHOT-system.rootfs.zst"}

export ROOTFS_FLAVOR=steamos
export STEAMOS_SNAPSHOT
export ROOTFS_BASE_URL=$STEAMOS_ROOTFS_URL
export ROOTFS_ARCHIVE_SHA256=$STEAMOS_ROOTFS_SHA256
export ROOTFS_DISTRIBUTION_NAME='SteamOS Holo core ARM64 preview'
export PACMAN_SERVER=$STEAMOS_PACMAN_SERVER
export PACKAGE_CACHE=${PACKAGE_CACHE:-"$project_dir/build/steamos-pacman-cache"}

exec "$project_dir/scripts/package-archlinuxarm-rootfs.sh" \
	"$output" "$source_archive"
