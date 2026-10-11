# 彩虹 Linux rootfs

[English](README.md) | 简体中文

本仓库为一加平板 Pro（`caihong`）构建 Arch Linux ARM 用户空间、配套的
mainline Linux 内核和 Android boot 镜像。目前属于该设备的开发版本，安装前请先
阅读下方设备状态表。

boot 镜像采用 Android boot image v2 格式，仅包含 Linux `Image` 和 Caihong
设备树，不含 ramdisk。双系统镜像直接挂载 GPT 分区名为 `linux` 的分区：

```text
root=PARTLABEL=linux rootfstype=ext4 rootwait rw
```

单系统镜像则挂载 `PARTLABEL=userdata`。所有可加载驱动、固件和设备专用用户空间
组件都存放在 rootfs 中。

## 设备状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 显示、GPU | 基本正常 | 3000×2120 内屏、Adreno GPU、亮度调节；偶尔仍会出现小面积屏幕花屏。 |
| 触摸与手写笔 | 正常 | 10 点触控、悬停、压感、绘画、休眠恢复、磁吸充电和首次自动配对已验证。 |
| Pogo 键盘 | 基本正常 | 键盘、触控板和功能键映射可用；按键时触控板可能短暂停顿。 |
| Wi-Fi | 基本正常 | 联网、硬件 MAC 和 STA/AP 并发可用；休眠恢复偶尔偏慢，BDF 目前使用兼容的厂商条目而非 Caihong 专属校准。 |
| 蓝牙 | 正常 | 扫描、配对、BLE、HID 和手写笔电量可用。 |
| 摄像头与闪光灯 | 基本正常 | 前后摄、自动对焦、软件 ISP、模组校准、手电筒和同步单闪可用；没有原厂硬件 ISP 与完整原厂调校。 |
| 传感器与霍尔开关 | 正常 | 加速度计、陀螺仪、环境光、自动亮度和保护套霍尔开关可用。 |
| 音频 | 正常 | 麦克风和立体声扬声器可用；音量低于原厂 Android，未包含 Dolby 和完整原厂调音。 |
| USB 与外接显示 | 正常 | USB host/device 控制器和 DP Alt Mode 可用。 |
| CPU 与休眠 | 正常 | CPU 调频和休眠恢复可用；默认关闭 3.3024 GHz boost。 |
| 电池与快充 | 基本正常 | 电量显示以及已测试的 PPS/VOOC 快充可用；其他充电协议暂未适配。 |
| 存储 | 正常 | 存储功能可用，MCQ 队列与完整频率表尚未配置。 |

## 发布文件

- `caihong-boot-linux-<kernel-release>.img`：双系统镜像，根分区使用
  `linux`。
- `caihong-boot-userdata-<kernel-release>.img`：单系统镜像，根分区使用
  `userdata`。
- `caihong-rootfs-<kernel-release>.tar.zst`：rootfs 压缩包；大于等于
  2 GiB 时会拆分为按顺序排列的 `.part-00`、`.part-01` 等文件。
- `linux-caihong-<version>-1-aarch64.pkg.tar.zst`：包含两种 boot 镜像
  和配套内核模块的 pacman 软件包。

Release 说明会记录各文件 SHA-256、重组后 rootfs 的 SHA-256 以及实际使用的源码
版本。可安装资产不会使用 ZIP 打包。

## 安装方法

需要已解锁的 bootloader，以及能够访问目标分区的 Linux 或合适的 recovery
环境。请先备份目标分区中的数据。

选择一种布局：

- **双系统：** 使用已有且 GPT `PARTLABEL` 为 `linux` 的分区，并选择
  `caihong-boot-linux-*.img`。
- **单系统：** 使用现有的 `userdata` 分区，并选择
  `caihong-boot-userdata-*.img`。格式化该分区会删除 Android 用户数据。

下载对应 boot 镜像和 rootfs 文件，并与 Release 说明中的 SHA-256 对比：

```sh
sha256sum caihong-boot-*.img caihong-rootfs-*.tar.zst.part-*
```

如果 rootfs 被拆分，按编号顺序合并：

```sh
cat caihong-rootfs-*.tar.zst.part-* > caihong-rootfs.tar.zst
```

在 Linux 或 recovery 中通过 GPT 分区名核对目标。将 `ROOTFS` 设为下载的压缩包，
或上一步合并得到的 `caihong-rootfs.tar.zst`。确认 `lsblk` 输出后才能替换下面的
`/dev/TARGET`：

```sh
lsblk -o PATH,SIZE,FSTYPE,LABEL,PARTLABEL
TARGET=/dev/TARGET
ROOTFS=caihong-rootfs.tar.zst

sudo umount "$TARGET" 2>/dev/null || true
sudo mkfs.ext4 -F -L linux "$TARGET"
sudo mkdir -p /mnt/caihong-rootfs
sudo mount "$TARGET" /mnt/caihong-rootfs
sudo bsdtar --numeric-owner --acls --xattrs -xpf "$ROOTFS" \
  -C /mnt/caihong-rootfs
sudo sync
sudo umount /mnt/caihong-rootfs
```

首次启动扩容服务使用文件系统标签 `linux`；boot 镜像仍按前述 GPT
`PARTLABEL` 选择根分区。

进入 fastboot 后先查看当前槽位，再明确选择用于 Linux 的槽位。不要覆盖需要保留
Android 的槽位：

```sh
fastboot devices
fastboot getvar current-slot

LINUX_SLOT=b
BOOT=caihong-boot-linux-<kernel-release>.img
fastboot flash "boot_${LINUX_SLOT}" "$BOOT"
fastboot --set-active="$LINUX_SLOT"
fastboot reboot
```

单系统安装时将 `BOOT` 改为 `userdata` 版本。Linux 首次成功启动后会记录实际
启动槽，并仅将该槽标记为启动成功。

## 默认用户和密码

| 用户 | 密码 | 用途 |
| --- | --- | --- |
| `alarm` | `alarm` | Plasma 桌面用户；属于 `wheel` 组，可使用自身密码运行 `sudo`。 |
| `root` | `root` | 系统管理员用户。 |

以 `alarm` 登录后，请立即修改两个账户的密码：

```sh
passwd
sudo passwd root
```

## Caihong 用户空间工具

rootfs 在 `/usr/local` 中预装以下设备专用工具。修改硬件或启动状态的命令需要
root 权限。

| 工具 | 用途与示例 |
| --- | --- |
| `caihong-slot` | 查看或切换 A/B 槽：`sudo caihong-slot status`、`sudo caihong-slot android --reboot`。 |
| `caihong-flashlight` | 控制后置手电筒：`sudo caihong-flashlight on 40`、`status` 或 `off`。 |
| `caihong-hotspot` | 在保持 STA 连接的同时启动热点：`sudo caihong-hotspot start`；还支持 `status`、`stop` 和 `regulatory {show\|set CODE\|reset}`。配置文件为 `/etc/caihong-hotspot.conf`。 |
| `caihong-hardware-mac` | 从设备冗余 NVRAM 读取并在启动时应用原厂 WLAN 与蓝牙地址。 |
| `caihong-bluetooth-autostart` | 启动时打开已经配置地址的蓝牙控制器。 |
| `caihong-pen-pair` | 使用通过 CPS8601 磁吸事件校验得到的地址配对手写笔，通常由 systemd 定时器调用。 |
| `caihong-pen-charge` | 执行有时间限制的 CPS8601 充电与吸附观察，通常由 systemd 定时器调用。 |
| `caihong-pen-autoconnect` | 恢复已配对手写笔连接和触摸屏手写笔扫描模式，通常由 systemd 定时器调用。 |
| `caihong-mark-boot-successful` | 记录实际启动槽，并只将该槽标记为启动成功；开机时自动运行。 |
| `caihong-fix-kwin-brightness` | 将参考原厂的环境光曲线写入 `alarm` 用户的 KWin 显示配置。 |
| `caihong-clean-pogo-kde` | 删除不适用于 Pogo 键盘的 KDE 键盘背光操作。 |
| `caihong-nvram-mac` | 位于 `/usr/local/libexec` 的内部读取器，由 `caihong-hardware-mac` 调用。 |
| `caihong-switch-to-android.desktop` | Plasma 应用菜单中的“切换到 Android”入口，通过 polkit 执行 `caihong-slot android --reboot`。 |

rootfs 还包含 Caihong SSC 服务、定制 libcamera、Plasma Camera 集成、设备固件、
音频拓扑和匹配的内核模块。

## 内核升级

使用 Release 中的 pacman 软件包升级内核、设备树和模块：

```sh
sudo pacman -U ./linux-caihong-*-aarch64.pkg.tar.zst
```

软件包会读取本次启动时记录的实际槽位，根据根分区是 `linux` 还是 `userdata`
选择镜像，只写入当前运行槽并读回校验。它不会修改 A/B 槽的 active、bootable 或
successful 标记。

## 本地构建

在 AArch64 主机上安装原生 GCC、Python 3、bsdtar、zstd、kmod 和
alsa-utils；其他架构还需要 AArch64 交叉编译器和 QEMU user-mode。脚本会自动
选择原生或交叉工具链：

```sh
scripts/checkout-dependencies.sh
scripts/build-kernel-release.sh
sudo -E env CHROOT_TOOL=chroot MODULE_TREE="$PWD/modules-current" \
  OUTPUT_FORMAT=tar scripts/package-archlinuxarm-rootfs.sh \
  "release/caihong-rootfs-$(cat release/KERNEL_RELEASE).tar.zst"
```

GitHub Actions 使用原生 AArch64 构建，并在不同运行之间保存 ccache。每个
Release 说明都会记录实际使用的各组件提交。

## 许可证

项目编写的构建脚本和工具采用 GPL-2.0-only，除非文件中另有 SPDX 声明。相机
调校数据保留其 CC0 声明；随附设备固件仍受厂商条款约束。
