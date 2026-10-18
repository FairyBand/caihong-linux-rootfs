#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Collect read-only runtime diagnostics for a booted Caihong device.
set -u

output=${1:-"/tmp/caihong-diagnostics-$(date +%Y%m%d-%H%M%S)"}
mkdir -p -- "$output"

run() {
	local name=$1
	shift
	{
		printf '$'
		printf ' %q' "$@"
		printf '\n\n'
		"$@"
	} >"$output/$name.txt" 2>&1 || printf '\n[exit status %s]\n' "$?" >>"$output/$name.txt"
}

run_shell() {
	local name=$1
	shift
	{
		printf '%s\n\n' "$*"
		bash -c "$*"
	} >"$output/$name.txt" 2>&1 || printf '\n[exit status %s]\n' "$?" >>"$output/$name.txt"
}

run_root_shell() {
	local name=$1
	shift
	{
		printf '%s\n\n' "$*"
		if [ "$(id -u)" -eq 0 ]; then
			bash -c "$*"
		else
			sudo -n bash -c "$*"
		fi
	} >"$output/$name.txt" 2>&1 || printf '\n[exit status %s]\n' "$?" >>"$output/$name.txt"
}

run_shell system "date -Is; hostnamectl 2>/dev/null || true; uname -a; cat /etc/os-release"
run_shell boot "cat /proc/cmdline; printf '\n'; cat /sys/firmware/devicetree/base/model 2>/dev/null || true; printf '\n'; tr '\0' '\n' </sys/firmware/devicetree/base/compatible 2>/dev/null || true; printf '\n'; cat /etc/caihong-rootfs-build-info 2>/dev/null || true; printf '\n'; cat /usr/lib/linux-caihong/kernel-release 2>/dev/null || true"
run_root_shell kernel "journalctl -b -k --no-pager; printf '\n== modules ==\n'; lsmod; printf '\n== failed units ==\n'; systemctl --failed --no-pager"
run_shell services "systemctl --no-pager --type=service --state=running; printf '\n== relevant units ==\n'; systemctl --no-pager list-unit-files | grep -Ei 'caihong|pipewire|wireplumber|iio|ssh|camera|power|display' || true"
run_root_shell drm "for d in /sys/class/drm/card*; do [ -e \"\$d\" ] || continue; echo ====\$d; cat \"\$d/status\" 2>/dev/null || true; cat \"\$d/modes\" 2>/dev/null || true; cat \"\$d/enabled\" 2>/dev/null || true; readlink -f \"\$d/device/driver\" 2>/dev/null || true; done; printf '\n== dmesg drm/gpu ==\n'; journalctl -b -k --no-pager | grep -Ei 'drm|dpu|mdss|dsi|gpu|adreno|msm|underrun|timeout|fence' || true"
run_root_shell backlight "for d in /sys/class/backlight/*; do [ -e \"\$d\" ] || continue; echo ====\$d; for f in actual_brightness brightness max_brightness bl_power type scale; do [ -e \"\$d/\$f\" ] && printf '%s=' \"\$f\" && cat \"\$d/\$f\"; done; done; printf '\n== ktz registers ==\n'; for f in /sys/bus/i2c/devices/*/reg_dump; do [ -e \"\$f\" ] && { echo ====\$f; cat \"\$f\"; }; done"
run_shell audio "cat /proc/asound/cards 2>/dev/null || true; printf '\n== aplay ==\n'; aplay -l 2>&1 || true; printf '\n== arecord ==\n'; arecord -l 2>&1 || true; printf '\n== wpctl ==\n'; wpctl status 2>&1 || true; printf '\n== pactl ==\n'; pactl list short 2>&1 || true; printf '\n== pipewire units ==\n'; systemctl --user --no-pager --type=service 2>&1 | grep -Ei 'pipewire|wireplumber' || true"
run_root_shell audio-kernel "release=\$(uname -r); printf 'kernel=%s\\n' \"\$release\"; journalctl -b -k --no-pager | grep -Ei 'snd|audio|soundwire|wcd|lpass|q6|apr|audioreach|aw88261|codec|firmware' || true; printf '\\n== loaded modules ==\\n'; lsmod | grep -Ei '(^| )(snd|soundwire|q6|lpass|wcd|aw88261)' || true; printf '\\n== modinfo paths and vermagic ==\\n'; for module in snd_pcm snd_pcm_dmaengine snd_soc_core snd_q6apm q6prm q6apm_dai q6apm_lpass_dais snd_soc_wcd939x_sdw snd_soc_aw88261 snd_soc_sc8280xp; do printf '\\n[%s]\\n' \"\$module\"; modinfo -F filename \"\$module\" 2>&1 || true; modinfo -F vermagic \"\$module\" 2>&1 || true; modprobe -n -v \"\$module\" 2>&1 || true; done; printf '\\n== module metadata ==\\n'; find /usr/lib/modules/\"\$release\" /lib/modules/\"\$release\" -maxdepth 1 -type f -name 'modules.*' -print -exec ls -l {} \\; 2>/dev/null | sort -u; printf '\\n== audio module files ==\\n'; find /usr/lib/modules/\"\$release\" /lib/modules/\"\$release\" -type f \( -name 'snd-*.ko*' -o -name 'q6*.ko*' -o -name 'snd_soc*.ko*' -o -name '*soundwire*.ko*' \) -print 2>/dev/null | sort -u"
run_shell gpu "command -v vulkaninfo >/dev/null && vulkaninfo --summary 2>&1 || true; printf '\n== glxinfo ==\n'; command -v glxinfo >/dev/null && glxinfo -B 2>&1 || true; printf '\n== vkmark ==\n'; command -v vkmark && timeout 20s vkmark --winsys wayland 2>&1 || true"
run_shell camera "command -v v4l2-ctl >/dev/null && v4l2-ctl --list-devices 2>&1 || true; printf '\n== media ==\n'; command -v media-ctl >/dev/null && media-ctl -p 2>&1 || true; printf '\n== cam ==\n'; command -v cam >/dev/null && cam -l 2>&1 || true; printf '\n== libcamera ==\n'; rpm -qa 2>/dev/null | grep -Ei 'libcamera|plasma-camera' || true"
run_root_shell input "cat /proc/bus/input/devices; printf '\n== evdev ==\n'; evtest --list-devices 2>&1 || true; printf '\n== novatek ==\n'; journalctl -b -k --no-pager | grep -Ei 'novatek|nt36532|pen|stylus|touch' || true"
run_shell sensors "command -v iio_info >/dev/null && iio_info -s 2>&1 || true; printf '\n== sensor proxy ==\n'; systemctl --no-pager status iio-sensor-proxy caihong-ssc 2>&1 || true; printf '\n== dbus sensor proxy ==\n'; gdbus introspect --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy 2>&1 || true"
run_root_shell power "cat /sys/power/state; cat /sys/power/mem_sleep 2>/dev/null || true; printf '\n== PSCI ==\n'; grep -H . /sys/firmware/psci/* 2>/dev/null || true; grep -H . /sys/kernel/debug/psci 2>/dev/null || true; printf '\n== wakeup ==\n'; grep -H . /sys/class/wakeup/*/name /sys/class/wakeup/*/active_count /sys/class/wakeup/*/event_count 2>/dev/null || true; printf '\n== power key ==\n'; journalctl -b --no-pager | grep -Ei 'power.?key|pwrkey|suspend|resume|wake|freeze' || true"
run_root_shell shutdown "printf '%s\n' '== boots =='; journalctl --list-boots --no-pager 2>&1 || true; printf '%s\n' '== current shutdown tail =='; journalctl -b --no-pager -o short-monotonic | grep -Ei 'shutdown|poweroff|systemd-shutdown|powering off|power down|reboot|halt' | tail -160 || true; printf '%s\n' '== previous shutdown tail =='; journalctl -b -1 --no-pager -o short-monotonic 2>&1 | grep -Ei 'shutdown|poweroff|systemd-shutdown|powering off|power down|reboot|halt' | tail -240 || true; printf '%s\n' '== pstore =='; find /sys/fs/pstore -maxdepth 1 -type f -print -exec sed -n '1,240p' {} \; 2>/dev/null || true; printf '%s\n' '== battery =='; for d in /sys/class/power_supply/*; do echo ===\$d; for f in type status capacity voltage_now current_now power_now energy_now charge_now; do [ -e \"\$d/\$f\" ] && printf '%s=' \"\$f\" && cat \"\$d/\$f\"; done; done"
run_shell userspace "printf 'display='; printf '%s\n' \"\${XDG_CURRENT_DESKTOP:-}\"; printf 'session='; printf '%s\n' \"\${XDG_SESSION_TYPE:-}\"; printf '\n== processes ==\n'; ps -eo pid,cls,rtprio,pri,ni,pcpu,pmem,comm,args --sort=-pcpu | head -80"

run_root_shell shutdown-history "printf '%s\n' '== last -x =='; last -x -F 2>/dev/null | head -60 || true; printf '%s\n' '== previous kernel terminal markers =='; journalctl -b -1 -k --no-pager 2>&1 | grep -Ei 'Power down|System halted|Rebooting system|PSCI|system.?off' | tail -120 || true"
printf 'Diagnostics written to %s\n' "$output"
