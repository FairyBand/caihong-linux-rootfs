#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -Eeuo pipefail
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
user_name=$(id -un)
outer_uid=$(id -u)
outer_gid=$(id -g)

IFS=: read -r _ subordinate_uid_start subordinate_uid_count < <(
	awk -F: -v user="$user_name" '$1 == user { print; exit }' /etc/subuid
)
IFS=: read -r _ subordinate_gid_start subordinate_gid_count < <(
	awk -F: -v user="$user_name" '$1 == user { print; exit }' /etc/subgid
)

if [[ -z ${subordinate_uid_start:-} || -z ${subordinate_gid_start:-} ]]; then
	echo "subordinate UID/GID ranges are not configured for $user_name" >&2
	exit 1
fi
if (( subordinate_uid_count < 65536 || subordinate_gid_count < 65536 )); then
	echo "rootless packaging needs at least 65536 subordinate UIDs/GIDs" >&2
	exit 1
fi

exec unshare \
	--user \
	--map-users "0:$outer_uid:1" \
	--map-users "1:$subordinate_uid_start:65536" \
	--map-groups "0:$outer_gid:1" \
	--map-groups "1:$subordinate_gid_start:65536" \
	--mount \
	--propagation private \
	--kill-child \
	--fork \
	env IMAGE_POPULATOR=mke2fs CHROOT_TOOL=chroot \
	"$project_dir/scripts/package-archlinuxarm-rootfs.sh" "$@"
