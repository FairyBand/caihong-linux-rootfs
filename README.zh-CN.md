# 彩虹 Fedora

[English](README.md) | 简体中文

这个 `fedora` 分支为一加平板 Pro（`caihong`）构建 Fedora Workstation 44（GNOME，
AArch64）：基于主线的 Caihong 内核、Android boot 镜像，以及 Fedora rootfs。设备适配
以 RPM 形式由 Copr 项目
[`fairyband/caihong`](https://copr.fedorainfracloud.org/coprs/fairyband/caihong/)
提供。

本仓库 fork 自
[Osilvfe/caihong-linux-rootfs](https://github.com/Osilvfe/caihong-linux-rootfs)。
`main` 分支跟随上游，构建 Arch Linux ARM 和 Armada 镜像；Fedora 分支去掉了这两条
构建路径，只保留 Fedora 需要的部分。这是开发中的移植，安装前请先阅读
[TODO.md](TODO.md)。

## 状态

未解决的问题和已完成的工作记录在 [TODO.md](TODO.md)。目前在 Fedora 上已验证：

- 内置屏幕上的 GNOME 和 Adreno 750 GPU（Mesa/Vulkan；vkmark 需要能被 3 整除的
  窗口尺寸，见 TODO.md）。
- Iris 硬件视频编解码：FFmpeg `h264_v4l2m2m`、`hevc_v4l2m2m`，以及通过
  `obs-studio-plugin-v4l2m2m` 在 OBS Studio 中录制和推流。
- Wi-Fi、蓝牙、Pogo 键盘、音频、SSC 传感器和内核 A/B 更新器均已打包。前后摄像头
  采集目前仍是黑帧。

SELinux 默认运行在 `permissive` 模式，服务策略尚未编写，参见
[docs/fedora44-gnome-migration-research.zh-CN.md](docs/fedora44-gnome-migration-research.zh-CN.md)。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `scripts/checkout-dependencies.sh`、`dependencies.env` | 按配置的分支获取 Caihong Linux 源码树和 `mkbootimg`。 |
| `scripts/build-kernel-release.sh` | 应用 `packaging/kernel/caihong-fedora-selinux.config` 构建内核、模块和两种直接根分区 boot 镜像。 |
| `scripts/package-fedora-rootfs.sh` | 以官方 Workstation raw 镜像和 Copr 软件包构建 Fedora ext4 rootfs。 |
| `scripts/verify-fedora-rootfs.sh` | 检查构建出的 rootfs：发行版、Copr 包 EVR、SELinux 和内核载荷。 |
| `scripts/collect-caihong-diagnostics.sh` | 在运行中的设备上收集日志和硬件状态。 |
| `rootfs/caihong/` | 设备集成覆盖层（udev、systemd 单元、板级工具、UCM2），其中大部分文件由 Copr 包安装。 |
| `firmware/`、`firmware-assets/` | 设备固件和 SSC 用户空间载荷，附 SHA-256 清单。 |
| `external/audioreach-topology/` | `firmware/` 中 AudioReach topology 的源码。 |
| `.github/workflows/fedora-rootfs.yml` | 在原生 ARM64 runner 上构建内核、boot 镜像和 rootfs。 |

RPM spec 位于
[FairyBand/caihong-fedora-rpms](https://github.com/FairyBand/caihong-fedora-rpms)：
`caihong-device-support`、`caihong-firmware`、`caihong-audio`、`caihong-ssc`、
`caihong-qbootctl`、`caihong-kernel-updater`、`caihong-kernel-payload`，以及重建的
`libcamera`、`plasma-camera`、`ffmpeg` 和 `obs-studio-plugin-v4l2m2m` 插件。

## 构建产物

在 Actions 页面运行 `Build Fedora Caihong rootfs` 工作流，它会上传：

- `caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img`：可直接刷写的 Android
  sparse ext4 rootfs，卷标为 `linux`。
- `caihong-boot-linux-<kernel-release>.img`：双系统 `linux` 分区使用的 boot 镜像。
- `caihong-boot-userdata-<kernel-release>.img`：单系统 `userdata` 使用的 boot 镜像。
- `SHA256SUMS.fedora`、`SHA256SUMS.boot`、boot 镜像清单和内核
  `config-<kernel-release>`。

刷写前用 `SHA256SUMS.fedora` 校验每个文件：

```sh
sha256sum -c SHA256SUMS.fedora
```

## 安装方法

请严格按步骤操作。分区或刷写目标错误可能清除 Android 和其他设备数据。

### 前置条件

- Bootloader 已解锁。
- 电脑上已安装 `adb` 和 `fastboot`。
- 已备份重要的 Android 数据和内部存储数据。
- boot 镜像和 rootfs 来自同一次工作流运行。
- 双系统安装需要一个名为 `linux` 的 GPT 分区，且大于 rootfs 的逻辑大小（目前约
  10 GiB）。如果已经存在，跳过下面的分区步骤。

### 双系统安装

#### 1. 创建或核对 Linux 分区

`fastboot` 无法缩小 GPT `userdata` 分区并创建 `linux`。已有 `linux` 时跳过本步，
否则进入能运行 `parted` 或 `sgdisk` 的 recovery：

```sh
adb reboot recovery
```

在 bootloader 中，如果设备支持该目标，可以使用 `fastboot reboot recovery`；否则执行
`fastboot reboot` 后用 recovery 组合键进入。

在 recovery 中先只运行以下只读命令，不要猜测整盘设备名：

```sh
adb wait-for-device
adb shell 'id; getprop ro.bootmode'
adb shell 'ls -l /dev/block/by-name/userdata /dev/block/by-name/boot_a /dev/block/by-name/boot_b'
adb shell 'ls -l /dev/block/by-name/dtbo_a /dev/block/by-name/dtbo_b'
adb shell 'cat /proc/partitions'
adb shell 'command -v parted; command -v sgdisk; command -v mkfs.f2fs'
```

根据 `userdata` 链接目标（例如 `/dev/block/sdaXX`）确定所在整盘（例如
`/dev/block/sda`）。备份 GPT 并打印按扇区的分区布局：

```sh
adb shell 'sgdisk --backup=/tmp/caihong-gpt.bin /dev/block/sda'
adb pull /tmp/caihong-gpt.bin ./caihong-gpt-before.bin
adb shell 'parted /dev/block/sda unit s print'
```

如果 recovery 没有 `sgdisk`，推送一个静态 `parted`，并在修改前保存 `print` 输出：

```sh
adb push /path/to/parted /tmp/parted
adb shell
chmod +x /tmp/parted
/tmp/parted /dev/block/sda
```

F2FS 无法缩小，因此要删除并重建 `userdata`：保留原起点，在分割点结束；`linux`
使用分割点到原 `userdata` 终点的空间。替换所有尖括号中的值：

```text
unit s
print
rm <userdata-number>
mkpart primary <original-userdata-start> <linux-start>
name <new-userdata-number> userdata
mkpart primary <linux-start> <original-userdata-end>
name <new-linux-number> linux
print
quit
```

确认 GPT 名称正好是 `userdata` 和 `linux`，然后用设备自带的 `mkfs.f2fs` 重新格式化
userdata（会删除 Android 用户数据）：

```sh
mkfs.f2fs -f /dev/block/by-name/userdata
```

不要格式化 `linux`，fastboot 会把 ext4 sparse rootfs 写入其中。如果
`/dev/block/by-name` 仍显示旧布局，先重新进入 recovery。然后返回 bootloader：

```sh
exit
adb reboot bootloader
```

#### 2. 刷写镜像

明确选择 Linux 槽位，下例使用 B 槽：

```sh
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
ROOTFS=caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash linux "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

只擦除 Linux 槽位的 DTBO。Caihong DTB 已包含在 boot 镜像中，请保留 Android 槽位的
DTBO。

### 单系统安装

这会覆盖 `userdata` 并删除 Android 用户数据：

```sh
adb reboot bootloader
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-userdata-<kernel-release>.img
ROOTFS=caihong-fedora-rootfs-<kernel-release>.ext4.sparse.img

fastboot erase "dtbo_${LINUX_SLOT}"
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot flash userdata "$ROOTFS"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

### 首次启动

镜像的 `/etc/machine-id` 为空并带有 `.autorelabel` 标记。首次启动会重新标记
SELinux 上下文并重启，之后由 GNOME 初始设置创建用户账户。
`caihong-grow-rootfs.service` 把 ext4 文件系统扩展到整个分区，
`caihong-mark-boot-successful.service` 把当前运行的槽位标记为成功。

## 更新

镜像已启用 `fairyband/caihong` Copr 仓库，常规的 Fedora 更新也会更新设备软件包：

```sh
sudo dnf upgrade --refresh
```

Caihong 的 `libcamera` 和 `ffmpeg` 构建使用 `Epoch: 1` 并带有 DNF5 仓库覆盖配置，
因此不会被 Fedora 官方包替换。

内核更新由两个包完成。`caihong-kernel-payload` 包含某个内核版本的 Image、DTB、
boot 镜像和模块，它由内核发布归档构建，不在普通 Copr 源码构建中生成。
`caihong-kernel-updater` 提供 `caihong-kernel-install`，用于启动
`caihong-kernel-install.service`；该服务也会在开机时运行。它识别根分区卷标
（`linux` 或 `userdata`），只把对应的 boot 镜像写入当前运行的槽位，并读回校验。
RPM 事务本身不写块设备，也不修改 A/B 的 active、bootable 和 successful 标志。

```sh
sudo dnf install ./caihong-kernel-payload-<version>.aarch64.rpm
sudo caihong-kernel-install
```

## 板级工具

以下工具由 `caihong-device-support` 安装在 `/usr/local` 下。修改硬件或启动状态的
命令需要 root 权限。

| 工具 | 用途和示例 |
| --- | --- |
| `caihong-slot` | 查看或切换 A/B 槽位：`sudo caihong-slot status`、`sudo caihong-slot android --reboot`。 |
| `caihong-flashlight` | 控制后置手电筒：`sudo caihong-flashlight on 40`、`status`、`off`。 |
| `caihong-hotspot` | 在不断开 STA 的情况下开启并发 Wi-Fi 热点：`sudo caihong-hotspot start`、`status`、`stop`、`regulatory {show\|set CODE\|reset}`。配置文件为 `/etc/caihong-hotspot.conf`。 |
| `caihong-hardware-mac` | 开机时从 NVRAM 读取并应用出厂 WLAN 和蓝牙地址。 |
| `caihong-bluetooth-autostart` | 开机时打开蓝牙控制器电源。 |
| `caihong-pen-pair`、`caihong-pen-charge`、`caihong-pen-autoconnect` | 手写笔配对、充电观测和自动重连，由 systemd 定时器运行。 |
| `caihong-mark-boot-successful` | 只把实际启动的槽位标记为成功，开机自动运行。 |
| `caihong-switch-to-android.desktop` | 应用菜单项，通过 polkit 重启到 Android。 |

## 本地构建

在 x86_64 Fedora 主机上安装 `gcc-aarch64-linux-gnu`、`qemu-user-static`、`rpm`、
`rsync`、`e2fsprogs` 和 `android-tools`（提供 `img2simg`）。AArch64 主机使用原生
编译器，不需要 QEMU。

```sh
scripts/checkout-dependencies.sh
CROSS_COMPILE=aarch64-linux-gnu- scripts/build-kernel-release.sh
sudo -E env COPR_REPO=fairyband/caihong SELINUX_MODE=permissive \
  MODULE_TREE="$PWD/modules-current" RELEASE_DIR="$PWD/release" \
  scripts/package-fedora-rootfs.sh
```

构建脚本会下载固定版本的 Fedora 44 Workstation raw 镜像，仅把它当作内容来源：启用
Copr，安装 Caihong 设备、固件、音频、SSC、相机和内核更新器 RPM，覆盖
`rootfs/caihong/`，安装匹配的模块和 boot 载荷，最后为 Android 直接根分区启动路径
重新生成 `LABEL=linux` 的 ext4 镜像。服务策略就绪后，用 `SELINUX_MODE=enforcing`
重新构建。在挂载的镜像上运行 `scripts/verify-fedora-rootfs.sh ROOTFS_DIR` 进行检查。

## 许可证

除文件另行声明 SPDX 许可证外，本项目编写的构建脚本和工具采用 GPL-2.0-only。相机
调校数据保留其声明的 CC0 许可证。随附的设备固件仍受其厂商条款约束。
