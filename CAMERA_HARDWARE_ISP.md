# Caihong 相机硬件 ISP 迁移

## 最终状态

Caihong 的正式相机路径已经从 libcamera 软件 ISP 全面迁移到 SM8650
Camera ICP/BPS：

```text
SC820CS / SC1320CS RAW10
        -> Camera ICP/BPS
        -> demosaic
        -> sensor white balance + adaptive AWB
        -> sensor CCM
        -> NV12M
        -> libcamera / GStreamer / Plasma Camera
```

发布构建使用 `-Dipas=` 和 `-Dsoftisp-gpu=disabled`，不构建 simple IPA、
`SoftwareIsp` 或 soft-IPA proxy。安装脚本会删除旧软件 ISP 文件，rootfs 验证器
也会在发现这些文件或硬件链元数据不完整时失败。不存在回退到软件 ISP 的运行
路径。

## 七批迁移结果

1. AE：libcamera 抽样硬件 NV12 输出亮度，闭环调节传感器曝光与模拟增益。
2. 固定白平衡：BPS 使用 SC820CS、SC1320CS 各自的传感器校准增益。
3. 动态 AWB：libcamera 抽样低饱和度 NV12 色度，通过 V4L2 Q10 红、蓝增益控制
   调整 BPS；启动后按多帧渐进收敛，避免颜色突变。
4. CCM：BPS 使用两颗传感器各自的 5200 K 矩阵，并转换到输出 YUV 色域。
5. Gamma 顺序验证：三通道 256 项、12-bit base/delta LUT 的 DMI 基础设施已完成，
   但 BPS Gamma 位于当前折叠进 CCM 的白平衡之前，非线性曲线会破坏通道校准，
   因此在白平衡迁移到 Gamma 前级之前保持关闭。
6. 双摄联调：前摄 3264x2448、后摄 4208x3120 各连续运行 80 帧，约 24 fps，
   序号均为 `0..79`，没有 HFI/BPS 帧错误。
7. 收尾：打包器记录完整硬件链；验证器强制检查主 ICP、BPS、两颗传感器模块
   以及软件 ISP 的缺失状态。

关键源码提交包括：

- Linux `fc2d40df549f`：V4L2 动态白平衡控制；
- Linux `0f1840719cc1`：传感器 CCM；
- Linux `2a6e69470beb`：BPS Gamma/DMI 最终实现；
- Linux `4e8ac745d93b`：在白平衡前移前暂缓启用 BPS Gamma；
- libcamera `e2583ebf2`：硬件输出亮度 AE；
- libcamera `0b0479ef2`：硬件输出色度 AWB；
- rootfs `95a5596`：双摄硬件 ISP 发布验证。

## 模块 ABI 约束

`qcom_camera_icp.ko` 与 `qcom-camera-icp-bps.ko` 共享 BPS job 结构，必须来自同一
次内核源码构建。混装旧 BPS 模块会导致白平衡字段错位和逐帧 `-EINVAL`。发布
验证器会同时检查两个模块，但手动热替换时也必须成套替换并执行 `depmod`。

## 实机验证

相机数字索引会随探测顺序变化，验证时使用完整设备路径。以下命令不会落盘原始帧：

```sh
cam -c /base/soc@0/cci@ac15000/i2c-bus@0/camera@10 --capture=80 \
  -s role=viewfinder,width=3264,height=2448
cam -c /base/soc@0/cci@ac15000/i2c-bus@1/camera@36 --capture=80 \
  -s role=viewfinder,width=4208,height=3120
```

验收条件：

- 两路命令返回 0，序号连续到 79；
- 前后摄画面不再全绿、严重欠曝或固定洋红；
- `dmesg` 中没有新的 `HFI command failed`、`BPS frame failed`、`0xa0008`
  或 `-121`；
- `/usr/share/caihong/libcamera-build-info` 包含硬件链、CCM、Gamma 暂缓状态、
  双摄验证和 `software_isp=disabled` 元数据；
- rootfs 中不存在 `ipa_soft_simple.so`、`soft_ipa_proxy` 和旧 simple IPA 调校
  文件。

## 剩余限制

- ICP 固件内部的 3A 统计尚未开放，AE/AWB 目前抽样已经转换后的 NV12 输出；
- AWB 从单位增益渐进收敛，启动后的前几十帧可能有短暂色偏；
- 后摄传感器请求宽度 4224 时会按硬件边界调整为 4208；
- 目前使用每颗传感器的固定 CCM，尚未按色温插值多组矩阵。
- BPS Gamma 必须等待白平衡增益迁移到其前级后再启用。
