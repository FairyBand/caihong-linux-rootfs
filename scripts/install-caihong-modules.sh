#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
set -eu
CDPATH=

project_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
module_root=${1:-"$project_dir/modules-current"}
target=${2:-"$project_dir/rootfs-stage"}
expected_release=${CAIHONG_EXPECTED_RELEASE:-}

if [ ! -d "$module_root/lib/modules" ]; then
	echo "module tree not found: $module_root/lib/modules" >&2
	exit 1
fi

module_root=$(cd -- "$module_root" && pwd)
mkdir -p "$target"
target=$(cd -- "$target" && pwd)

release=
for candidate in "$module_root"/lib/modules/*; do
	[ -d "$candidate" ] || continue
	if [ -n "$release" ]; then
		echo "more than one kernel release exists below $module_root/lib/modules" >&2
		exit 1
	fi
	release=${candidate##*/}
done

if [ -z "$release" ]; then
	echo "no installed kernel release found" >&2
	exit 1
fi

if [ -n "$expected_release" ] && [ "$release" != "$expected_release" ]; then
	echo "kernel module tree release mismatch: $release (expected $expected_release)" >&2
	exit 1
fi

# These are the useful module roots for the current Caihong device tree:
# ADSP/CDSP remoteproc, QRTR/PD mapper, FastRPC, WCN7850 WLAN/Bluetooth,
# battery management, pstore, and SoC identification. Dependencies are
# resolved by the host modprobe. Built-in roots produce no .ko and are safe to
# keep here, which prevents another configuration change from silently
# dropping battery or WLAN support from a packaged rootfs.
roots="qcom_q6v5_pas qrtr_smd qrtr_mhi qcom_pd_mapper fastrpc hci_uart hid_multitouch ramoops socinfo qcom_battmgr pwrseq_qcom_wcn pci_pwrctrl_pwrseq ath12k_wifi7 system_heap cma_heap camcc_sm8650 i2c_qcom_cci v4l2_cci qcom_camss leds_qcom_flash pinctrl_sm8650_lpass_lpi soundwire_qcom snd_q6apm q6prm q6prm_clocks q6apm_dai q6apm_lpass_dais snd_soc_lpass_va_macro snd_soc_lpass_wsa_macro snd_soc_lpass_rx_macro snd_soc_lpass_tx_macro snd_soc_wcd939x_sdw snd_soc_wcd939x snd_soc_aw88261 snd_soc_sc8280xp oneplus_pogo nt36532e_ts sc8547_cp caihong_pen_power sc820cs sc1320cs gt9772"

list=$(mktemp)
depends=$(mktemp)
trap 'rm -f -- "$list" "$depends"' EXIT HUP INT TERM

for module in $roots; do
	if grep -q "/$module\\.ko$" \
		"$module_root/lib/modules/$release/modules.builtin"; then
		echo "module built in: $module"
		continue
	fi
	if ! modprobe -d "$module_root" -S "$release" \
		--show-depends "$module" > "$depends"; then
		echo "failed to resolve module: $module" >&2
		exit 1
	fi
	awk '$1 == "insmod" { print $2 }' "$depends" >> "$list"
done

sort -u "$list" -o "$list"
dest_release="$target/lib/modules/$release"
mkdir -p "$dest_release"
# The caller may reuse a staging tree.  Never leave a previous kernel release
# or an old dependency closure mixed into the new rootfs.
find "$target/lib/modules" -mindepth 1 -maxdepth 1 \
	! -path "$dest_release" -exec rm -rf -- {} +
find "$dest_release" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

count=0
while IFS= read -r module; do
	[ -n "$module" ] || continue
	relative=${module#"$module_root"/}
	if [ "$relative" = "$module" ]; then
		echo "refusing module outside $module_root: $module" >&2
		exit 1
	fi
	install -D -m 0644 "$module" "$target/$relative"
	count=$((count + 1))
done < "$list"

for metadata in modules.builtin modules.builtin.modinfo; do
	if [ -f "$module_root/lib/modules/$release/$metadata" ]; then
		install -m 0644 "$module_root/lib/modules/$release/$metadata" \
			"$dest_release/$metadata"
	fi
done

awk -v prefix="$module_root/lib/modules/$release/" \
	'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }' \
	"$list" > "$dest_release/modules.order"

depmod -b "$target" "$release"

modules_load_conf="$project_dir/rootfs/archlinuxarm/etc/modules-load.d/caihong.conf"
if [ -f "$modules_load_conf" ]; then
	install -D -m 0644 "$modules_load_conf" \
		"$target/etc/modules-load.d/caihong.conf"
fi

echo "installed $count modules for $release into $dest_release"
