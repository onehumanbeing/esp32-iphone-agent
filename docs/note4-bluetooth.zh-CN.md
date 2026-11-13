# Zectrix Note 4 板型适配

[English](note4-bluetooth.md)

Note 4 是带电池的 4.2 英寸黑白墨水屏设备，主控为 ESP32-S3。本适配选择项目的[通用蓝牙键鼠能力](bluetooth-hid.zh-CN.md)，并提供板型所需的电源、引脚、电池和分区配置。

## Note 4 专用范围

- 电池供电时保持电源，并设置闲置外设引脚，避免噪声和额外耗电。
- 从本板 ADC 引脚读取电池电压，使用 Zectrix 参考曲线估算电量；该逻辑不属于通用 HID 模块。
- 使用 16 MB Flash、OPI PSRAM 和对应分区，单独输出镜像。
- 状态中的 `board: note4` 表示板型，`hid` 字段独立表示蓝牙输入能力和状态。

本次没有新增墨水屏显示、语音待办等原厂功能。画面继续使用项目现有 AirPlay/Wi-Fi 路径。

## 构建板端固件

在仓库根目录运行以下命令，产物位于 `hardware/build/note4/`。命令只编译，不执行安装。

```sh
hardware/flash.sh --note4 --build-only
```

Note 4 首次部署使用有线方式，部署前需核对实物板型、完整 Flash 备份和分区表。本候选版本的脚本只为 Note 4 编译镜像。项目网页刷机入口和 App 的 USB 固件更新仅供标准板使用。

## 连接和检查

安装后按[通用配对与验证步骤](bluetooth-hid.zh-CN.md#配对与验证)操作。除配对、重连和手机实际输入外，Note 4 还需要检查电池供电、电量读数以及断电后的恢复情况。
