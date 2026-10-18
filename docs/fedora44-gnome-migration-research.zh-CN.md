# Fedora Workstation 44 GNOME 迁移调查

调查日期：2026-10-15  
仓库基线：`main`，`4a343b6`  
目标：OnePlus Pad Pro (`caihong`) 的 Fedora Workstation 44 ARM64、GNOME、SELinux enforcing 用户空间，同时保留现有 Caihong 内核、DTB、固件和设备适配功能。

## 结论先行

迁移可行，但不能把现有 Arch rootfs 的包管理器和桌面包替换掉就结束。板级适配可以大部分复用，真正的发行版边界有四处：

| 项目 | 结论 | 迁移工作量 | 主要风险 |
| --- | --- | ---: | --- |
| SELinux | 必须改内核配置，并为自定义服务建立 Fedora policy | 高 | FastRPC、相机、原始分区写入在 enforcing 下被拒绝 |
| Pogo 键盘 | 内核和 libinput 路径与 GNOME 兼容；KDE 清理服务应删除 | 低 | GNOME/UPower 可能显示无效的键盘背光能力 |
| 自动亮度 | GNOME 原生支持，SSC 已经提供所需 SensorProxy 总线方向 | 中 | GNOME 算法不是当前 KWin 的原厂 lux 曲线 |
| 相机 | 自定义 libcamera 必须保留；Plasma Camera 可在 GNOME 运行 | 中高 | 直接覆盖 Fedora RPM 会被升级恢复；IPA 签名和文件所有权必须处理 |
| 内核更新 | 现有 A/B 写入逻辑与发行版无关，应拆成 Fedora RPM/服务 | 中高 | SELinux 约束 raw block device，事务中直接刷写不可取 |

Fedora 44 ARM64 Workstation 官方镜像是 `Fedora-Workstation-Disk-44-1.7.aarch64.raw.xz`，官方校验值为：

```text
SHA256 0361c13141e6f57e24d6ee5227066c33a45f7f92a95f41d0bbd343e4fd05da18
```

它是 Fedora 的磁盘镜像，不是现有 Android boot v2 的 `linux`/`userdata` 分区镜像。安装时仍应保留当前 Caihong boot image 机制，只提取 Fedora rootfs，重新制作 `LABEL=linux` 的 ext4 镜像。

## 1. SELinux

### 现状和差异

上游 Caihong 内核树为 `Osilvfe/linux:caihong-v7.2`。原始 `arch/arm64/configs/caihong_defconfig` 只显式打开了 `CONFIG_SECURITY=y`、`CONFIG_AUDIT=y` 和 `CONFIG_EXT4_FS_SECURITY=y`。对该 defconfig 执行 `olddefconfig` 后，关键结果是：

```text
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_SECURITYFS=y
CONFIG_DEFAULT_SECURITY_DAC=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,ipe,bpf"
# CONFIG_SECURITY_SELINUX is not set
# CONFIG_SECURITY_NETWORK is not set
# CONFIG_SECURITY_PATH is not set
```

因此，当前内核不是“SELinux 已启用但策略缺失”，而是没有编译 SELinux LSM。

Fedora 44 的 `kernel-aarch64-fedora.config` 明确包含：

```text
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_PATH=y
CONFIG_SECURITYFS=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="lockdown,yama,integrity,selinux,bpf,landlock,ipe"
CONFIG_IMA=y
CONFIG_EVM=y
```

SELinux 的 Kconfig 还要求 `SECURITY_NETWORK`、`AUDIT`、`NET`、`INET`，并选择 `NETWORK_SECMARK`。所以只在 defconfig 里增加 `CONFIG_SECURITY_SELINUX=y` 不够。

### 内核改造建议

第一版 Fedora 内核应在 Caihong defconfig 中加入并经 `olddefconfig` 验证：

```text
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_PATH=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf,ipe"
```

`CONFIG_SECURITY_SELINUX_DEVELOP=y` 便于首轮用 permissive 收集 AVC，再切换 enforcing；最终启动参数和 `/etc/selinux/config` 应以 enforcing 为目标。Fedora 的 IMA/EVM 不必作为 Caihong 第一阶段的硬门槛，可先保持 Fedora 配置默认值，但不要在没有签名和测量方案前宣称 IMA appraisal 已验证。

### 自定义策略的实际边界

现有 overlay 中有多个 Fedora policy 未覆盖的程序/访问路径：

* `caihong-ssc.service` 运行自定义 `hexagonrpcd`，打开 `/dev/fastrpc-adsp`，读取和写入 `/var/lib/caihong-ssc/root`。
* 自定义 `iio-sensor-proxy` 通过 system bus 提供 `net.hadess.SensorProxy`，并访问 SSC 设备状态。
* `caihong-hardware-mac` 读取 `/dev/disk/by-partlabel/nonmodemst1|2`，访问网卡 sysfs，并调用 `btmgmt`。
* `caihong-pen-charge` 会读取 SPI/platform sysfs，并在需要时加载 `/usr/local/lib/caihong/caihong_pen_power.ko`。
* `caihong-hotspot` 创建 AP 接口、改写 sysctl、nftables、hostapd 和 dnsmasq 状态。
* 相机和 `soft_ipa_proxy` 访问 `/dev/video*`、`/dev/v4l-subdev*`、DMA heap、固件和校准文件。
* `install-current-slot` 会读取 `/sys/firmware/devicetree`，访问 `/dev/disk/by-partlabel/boot_a|boot_b`，执行 `dd`、`blockdev`、`flock`，并激活模块树。

现有 `scripts/package-armada-rootfs.sh:261-262` 创建 `.autorelabel`，这只能解决新文件首次启动时的标签重建，不能替代内核 SELinux 或自定义 allow 规则。

建议为这些程序分别建小型 RPM policy 包，而不是把整个服务放进 permissive domain：

1. 先把可执行文件、服务、状态目录和设备节点用 Fedora `file_contexts` 固定类型，并运行 `restorecon`。
2. Fedora rootfs 首次启动用 `selinux=permissive`，保存 `ausearch -m AVC -ts boot` 输出。
3. 以服务为单位编写 `.te`/`.if`/`.fc`，只允许所需设备、sysfs、网络和 dbus 操作；不要直接把 `audit2allow` 的全部输出提交为最终策略。
4. SSC、相机和 kernel updater 分开切换 enforcing，避免一个 AVC 掩盖其他服务的问题。

SELinux 验收门槛：`getenforce` 为 `Enforcing`；`sestatus` 显示 targeted；启动后没有持续 AVC；`systemctl --failed` 为空；SSC、相机、Pogo pen、热点和 kernel updater 的功能测试全部通过。

## 2. Pogo 键盘和 GNOME

Pogo 的关键适配在内核驱动 [`oneplus_pogo.c`](https://github.com/Osilvfe/linux/blob/caihong-v7.2/drivers/input/keyboard/oneplus_pogo.c) 中完成，不依赖 KDE：

* 设备通过 serdev/UART 协议产生标准 evdev keyboard 和 touchpad 设备。
* 顶部按键在驱动中映射到 `KEY_F1` 到 `KEY_F12`。
* Search 键在驱动中作为 `KEY_FN`，Fn 组合键也由驱动处理。
* CapsLock 是 `EV_LED`，驱动负责把状态写回 Pogo。
* 触控板按键和短暂停顿处理属于驱动/输入事件时序，不是 KWin 行为。

现有 udev 规则 [99-caihong-pogo-input.rules](/home/kagami/文档/onepluspadprolinux/rootfs/archlinuxarm/etc/udev/rules.d/99-caihong-pogo-input.rules) 只设置：

```text
ID_INPUT_TOUCHPAD_INTEGRATION=external
LIBINPUT_ATTR_DISABLE_WHILE_TYPING=0
```

这条规则可以原样迁移到 Fedora，建议安装在 `/usr/lib/udev/rules.d/` 的 Caihong RPM 中，再用 `udevadm test` 和 `libinput debug-events` 验证。

需要删除或不安装的部分：

* `caihong-fix-kwin-brightness` 不属于 GNOME。
* `caihong-clean-pogo-kde` 只删除 PowerDevil 的键盘背光快捷键，并重启 Plasma 服务；GNOME 没有这些服务。
* Arch/Plasma 的 `kglobalshortcutsrc`、PowerDevil 插件删除逻辑不应进入 Workstation 镜像。

GNOME 首轮验收应覆盖：

```text
libinput debug-events                 # 普通键、F1-F12、Search/Fn、CapsLock
udevadm info --query=property --name=/dev/input/eventX
gsettings get org.gnome.desktop.peripherals.touchpad disable-while-typing
upower -d                             # 确认没有虚假的 KbdBacklight 设备
```

如果 GNOME Settings 显示键盘背光控制，先确认是否是 UPower 暴露的 `org.freedesktop.UPower.KbdBacklight`，再针对该设备做 UPower/udev quirk；不要用 KDE 服务替代。

## 3. 自动亮度

GNOME 自带自动亮度，不需要迁移 KWin 配置文件。当前 GNOME Settings Daemon 的流程是：

1. 通过 system bus 连接 `net.hadess.SensorProxy`。
2. 读取 `HasAmbientLight` 和 `LightLevel`。
3. `ambient-enabled` 的默认值是 `true`。
4. 调用 `ClaimLight`，对读数做低通滤波和归一化。
5. 通过 `org.gnome.Shell.Brightness.SetAutoBrightnessTarget` 设置目标亮度。

仓库现有 SSC 集成已经提供这条总线方向：

* [90-caihong-ssc.rules](/home/kagami/文档/onepluspadprolinux/scripts/ssc/90-caihong-ssc.rules) 给 `fastrpc-adsp` 设置 `IIO_SENSOR_PROXY_TYPE="ssc-accel ssc-light ssc-compass"`。
* [caihong-ssc.service](/home/kagami/文档/onepluspadprolinux/scripts/ssc/caihong-ssc.service) 启动 ADSP FastRPC listener。
* `iio-sensor-proxy.service.d/caihong-ssc.conf` 替换为 Caihong 的 SensorProxy 实现。

Fedora 44 自带 `iio-sensor-proxy` 的包和 systemd/DBus 集成，因此推荐保留 Fedora 包，只通过 drop-in 替换 Caihong 后端，并确认 unit 的 `ExecStart` 覆盖生效。

KWin 脚本使用的原厂曲线是：

```text
0, 8.96, 30.8, 71.4, 512, 952.5, 1304, 1651.5, 1867.3333333333333, 7030, 40000 lux
```

GNOME 使用“当前读数归一化 + 指数移动平均”，并不读取这 11 个阈值。因此第一阶段应接受 GNOME 原生曲线，先确认亮度能稳定响应；不能继续写 `kwinoutputconfig.json`。只有在真机 lux sweep 证明体验明显退化时，才考虑写 GNOME Shell 扩展或独立用户服务去实现 Caihong 曲线，这属于第二阶段 UI/策略工作。

验收命令和现象：

```sh
gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled
dbus-send --system --print-reply \
  --dest=net.hadess.SensorProxy /net/hadess/SensorProxy \
  org.freedesktop.DBus.Properties.Get string:net.hadess.SensorProxy string:LightLevel
monitor-sensor
journalctl -u iio-sensor-proxy -u caihong-ssc --since boot
```

需要用遮光、室内、强光至少三档重复测试，并记录实际 lux、屏幕亮度百分比和响应时间；“SensorProxy 有值”不能单独证明 GNOME 自动亮度工作。

## 4. 相机栈

Fedora 44 ARM64 的官方包已经提供：

* `libcamera`、`libcamera-ipa`、`libcamera-tools`、`libcamera-qcam`、`libcamera-gstreamer`。
* Fedora 44 分支当前 spec 为 `libcamera 0.7.2-2`，使用 `/usr/lib64`、IPA 签名和 RPM 子包。
* `plasma-camera 26.08.1` 可在 GNOME 中作为普通 Qt 应用运行。
* Fedora 还有 GTK/libadwaita 的 `snapshot` 应用，但它通过 GStreamer camerabin，必须先证明自定义 GStreamer libcamera pipeline 可用。

Caihong 构建脚本 [install-caihong-libcamera-rootfs.sh](/home/kagami/文档/onepluspadprolinux/scripts/install-caihong-libcamera-rootfs.sh) 的硬件相关选项必须保留：

```text
-Dpipelines=simple
-Dipas=simple
-Dsoftisp-gpu=enabled
-Dgstreamer=enabled
-Dqcam=enabled
```

还必须保留 `sc820cs.yaml`、`sc1320cs.yaml`、custom IPA、`soft_ipa_proxy`、动态 NVMEM calibration、V4L2 flash 工具和匹配的 kernel camera modules。Fedora 的 `/usr/lib64` 路径与现有 Armada 迁移脚本一致；这部分不是主要障碍。

真正的问题是现有 Armada 脚本直接把自定义文件 rsync 到 `/usr/lib64`，这会让 Fedora RPM 数据库认为文件属于官方包，下一次 `dnf upgrade` 可能覆盖它。Arch 方案通过 `IgnorePkg` 规避，Fedora 应改为以下任一正式方案：

* 建立 `caihong-libcamera` RPM，拥有自定义 `/usr/lib64/libcamera*`、IPA、GStreamer plugin 和 YAML；使用 `Conflicts/Obsoletes` 或明确的 `Provides` 替换 Fedora 同名子包。
* 或把自定义 libcamera 安装到 `/usr/lib64/caihong/libcamera`，通过 loader/plugin 配置和独立的 `caihong-plasma-camera` 使用；这会增加运行时路径和 IPA 搜索路径维护，优先级较低。

当前实现采用同名 `libcamera` RPM，并固定 `Epoch: 1`。Fedora 官方包目前没有
Epoch，因此任何普通版本号都不会覆盖已安装的 Caihong 包；同时 RPM 还安装
Fedora 44 DNF5 的 `/etc/dnf/repos.override.d/99-caihong-libcamera.repo`，在
`fedora*` 和 `updates*` 官方仓库中排除 `libcamera*`。这样 Copr 忘记重建时系统
会保持现有 Caihong 包，而不会回退到 Fedora 上游版本。Copr 仓库本身仍必须保持
启用；该策略不阻止 root 使用 `--disableexcludes=all` 或手动 RPM 强制替换。

建议第一阶段仍保留自定义 Plasma Camera，原因是它已经覆盖当前已验证的 autofocus、白平衡、软件 ISP、torch 和单闪同步功能。它是 Qt 应用，不会把桌面会话变成 KDE；但要在 GNOME 菜单中提供 desktop entry，并测试 Wayland 权限、PipeWire/GStreamer 和视频节点访问。若后续要求完全 GNOME 原生 UI，再单独适配 `snapshot` 或编写 GTK4 前端，不要在首轮同时重写相机前端和后端。

相机验收应同时覆盖：`cam -l`、`qcam`、Plasma Camera 前后摄切换、连续预览、自动对焦、JPEG、录像、torch、单闪同步，以及 `dnf upgrade` 后文件校验和 IPA 签名仍然正确。

## 5. 内核和 A/B 更新

当前 Arch 包 [linux-caihong.install](/home/kagami/文档/onepluspadprolinux/packaging/linux-caihong/linux-caihong.install) 的真正逻辑在 [install-current-slot](/home/kagami/文档/onepluspadprolinux/packaging/linux-caihong/install-current-slot)：

1. 识别当前 Android A/B slot。
2. 识别根分区是 `PARTLABEL=linux` 还是 `PARTLABEL=userdata`。
3. 激活匹配的 `/usr/lib/modules/<release>`。
4. 把对应的 Android boot v2 镜像写入当前运行 slot 的 `boot_a` 或 `boot_b`。
5. `dd` 后 `blockdev --flushbufs`，再读回比较校验。
6. 不修改 active、bootable、successful 标志。

这段逻辑不依赖 pacman，适合拆成 `caihong-kernel-updater` RPM，payload 保持：

```text
/usr/lib/linux-caihong/kernel-release
/usr/lib/linux-caihong/boot-linux.img
/usr/lib/linux-caihong/boot-userdata.img
/usr/lib/linux-caihong/modules/<release>
```

Fedora 版本不建议在普通 kernel RPM 的 `%post` 中直接刷 raw block device。推荐：

* RPM 安装阶段只落盘 payload 和校验清单。
* `%posttrans` 仅触发一个受 SELinux policy 保护的 `caihong-kernel-install.service`，或者要求管理员显式执行 `caihong-kernel-install`。
* 服务在写入前再次检查设备 compatible、当前 slot、root PARTLABEL、镜像大小和 SHA256；写入后读回校验。
* 保留正在运行的旧模块树，重启成功并由 `caihong-mark-boot-successful` 标记成功后再清理旧版本。
* 让 `dnf upgrade` 失败时不影响当前可启动的 boot image；失败状态必须能在 journal 中清楚发现。

SELinux 下这个 updater 需要专门允许访问 `boot_a/boot_b` block device、`/sys/firmware/devicetree`、`/usr/lib/modules`、`depmod` 和锁文件。它是迁移中最不适合直接套用 Fedora 通用 kernel scriptlet 的部分。

## 推荐迁移顺序和验收门槛

1. **内核先行**：加入 Fedora SELinux 配置，保留 Android boot v2、DTB、现有 Caihong 驱动和固件；先以 permissive 启动 Fedora rootfs。
2. **最小 GNOME rootfs**：从 Fedora Workstation 44 ARM64 raw 镜像提取 rootfs，保留 Fedora 的 systemd、NetworkManager、PipeWire、GNOME、SELinux targeted；只叠加 Caihong overlay。
3. **显示/SSC/亮度**：先让 `net.hadess.SensorProxy`、GNOME 自动亮度和显示亮度稳定工作，不迁移 KWin 曲线。
4. **Pogo 输入**：保留内核模块和 udev 规则，删除 KDE 专属 unit，完成 GNOME Wayland 输入测试。
5. **SELinux policy**：按 SSC、相机、pen、热点、kernel updater 分服务收集 AVC 并固化为 RPM policy。
6. **相机 RPM**：先打包 `caihong-libcamera` 和 `caihong-plasma-camera`，确认 `dnf upgrade` 不会替换自定义文件；之后再评估 `snapshot`。
7. **内核 updater RPM**：最后迁移 A/B 写入和回读验证，完成失败、断电和回滚测试。

以下任一项未通过，都不应把镜像称为“严格 Fedora Workstation 44”：

* `getenforce` 不是 `Enforcing`，或自定义服务仍靠全局 permissive 运行。
* GNOME 会话中 Pogo 键、Fn、触控板和 CapsLock 不稳定。
* GNOME 自动亮度只能看到 SensorProxy 数值，不能实际调节 DSI 背光。
* Fedora 升级后自定义 libcamera/IPA 被官方 RPM 覆盖。
* kernel updater 无法证明写入的是当前运行 slot，或没有读回校验。

当前阶段没有修改实现代码；本报告用于决定是否进入 Fedora rootfs 构建、内核配置和 policy/RPM 实现阶段。

## 依据

* [Fedora Workstation ARM64 下载页](https://fedoraproject.org/workstation/download/)
* [Fedora 44 Workstation ARM64 镜像目录](https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/images/)
* [Fedora 44 ARM64 kernel config](https://src.fedoraproject.org/rpms/kernel/blob/f44/f/kernel-aarch64-fedora.config)
* [Fedora 44 libcamera spec](https://src.fedoraproject.org/rpms/libcamera/blob/f44/f/libcamera.spec)
* [Fedora 44 plasma-camera spec](https://src.fedoraproject.org/rpms/plasma-camera/blob/f44/f/plasma-camera.spec)
* [Fedora 44 selinux-policy spec](https://src.fedoraproject.org/rpms/selinux-policy/blob/f44/f/selinux-policy.spec)
* [GNOME Settings Daemon power plugin](https://gitlab.gnome.org/GNOME/gnome-settings-daemon/-/blob/main/plugins/power/gsd-power-manager.c)
