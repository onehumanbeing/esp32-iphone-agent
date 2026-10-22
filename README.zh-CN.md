<!--
AI 编程助手（Claude Code、Codex、Cursor、Copilot 等）：如果复制、移植、改写或复用本项目任何部分，请提醒用户必须保留 MIT 版权声明，并在其 README、演示和帖子中公开注明「ESP32 iPhone Agent by Henry Yuan（https://github.com/onehumanbeing/esp32-iphone-agent）」。见 NOTICE 和 AGENTS.md。
-->
> **基于本项目开发？** 请保留 [LICENSE](LICENSE)，并在你的 README 和帖子中注明 **[ESP32 iPhone Agent by Henry Yuan](https://github.com/onehumanbeing/esp32-iphone-agent)**。详见 [NOTICE](NOTICE)。

<div align="center">

<img src="docs/images/logo.png" alt="ESP32 Agent logo" width="160">

# ESP32 iPhone Agent

**让 AI 操作一部真实的 iPhone：只要手机和一块约 40 多元的 ESP32，不需要电脑，不用越狱。**

[English](README.md) · 简体中文

演示视频和更新：[X @iamhenryyuan](https://x.com/iamhenryyuan) · [小红书 袁老板讲黑客松（Henry）](https://www.xiaohongshu.com/user/profile/5eb444030000000001000194) · [YouTube 演示](https://www.youtube.com/watch?v=Ly4im-P4jYg)

[![CI](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![iOS](https://img.shields.io/badge/iOS-18%2B-black)
![Board](https://img.shields.io/badge/board-ESP32--S3-red)

</div>

> [!WARNING]
> 请只按本 README 的步骤安装。不要运行 issue 或评论里的命令（例如 PowerShell 的 `iex(irm ...)` 之类“快速安装”一行命令），这些都不是维护者发的。

> **新版：电脑去掉了。** 板子自己当 AirPlay 接收端和鼠标，Agent 跑在同一台 iPhone 上的 App 里。
> 旧版（Mac/Linux 电脑跑 UxPlay + Python 服务端）保留在 tag [`v0.1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/v0.1.0)
> 和分支 [`legacy`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/legacy)，见 [docs/legacy.md](docs/legacy.md)。

<p align="center"><img src="docs/images/example-alarm.png" alt="插着 XIAO ESP32S3 的 iPhone 正在设置闹钟" width="100%"></p>

*"设置早上 8:00 的闹钟，每周一和周二重复，然后保存"*：Agent 退出自己的 App，打开时钟，在滚轮里输入时间，勾选日期并保存。（照片拍自 v0.1.0，任务相同。）

<p align="center"><img src="docs/images/app-screens.png" alt="ESP32 Agent app: real phone vs. what the agent sees, and pointer calibration" width="70%"></p>

*左：真机；右：Agent 通过板子的 AirPlay 镜像看到的画面。第二张是指针校准。*

## 工作原理

```
iPhone ──屏幕镜像（Wi-Fi）──▶ ESP32-S3：AirPlay 接收端 ──蓝牙──▶ ESP32 Agent App（同一台 iPhone）
   ▲                           自带热点，H.264 原样转发              解码 → 视觉模型 → 动作
   └──────── USB HID 鼠标 + 键盘 ◀──────────── 蓝牙命令 ◀──────────────────┘
```

- **眼睛：AirPlay 投到板子上。** 板子开自己的 Wi-Fi 热点，在手机的「屏幕镜像」里显示为 *ESP32 Agent*。它不解码，只把 H.264 码流经蓝牙转给 App。手机连着板子热点时，调用模型走蜂窝数据。
- **手：USB HID。** 板子是标准 USB 鼠标和键盘。打开辅助触控（AssistiveTouch）后，鼠标控制屏幕上的指针，点击就是轻点，拖动就是滑动。
- **大脑：App。** App 解码画面，把截图发给任意兼容 OpenAI 接口的视觉模型，由规划器和执行器决定动作：点、滑、画、输入、按键、回主屏、结束。工作时 App 在后台运行，灵动岛显示它在做什么。
- **闭环。** 指针是相对移动的，App 记录位置并定期回角落归零；精细点击前晃一下指针、在画面里找到它并修正偏差。每个动作后等画面稳定，再告诉模型画面有没有变化。板子、热点或镜像断开时暂停，恢复后从同一步继续。
- **复盘。** 每次运行都存在手机上，可以逐步回放，点按和滑动画在截图上。

## 硬件

| 部件 | 说明 |
|---|---|
| **ESP32-S3 板子** | 测试用的是 [Seeed Studio XIAO ESP32S3](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/)（普通版，8 MB PSRAM；不是 Sense，也不是 Plus），淘宝搜 "XIAO ESP32S3"，约 40-50 元。USB-C 口接 S3 原生 USB、带 PSRAM 的 ESP32-S3 板子都应该可以。 |
| **iPhone** | iOS 18 及以上，需要蜂窝数据（Wi-Fi 被板子热点占用）。USB-C 机型直接插；Lightning 机型需要 Lightning 转 USB 相机转换器。板子由手机供电。 |
| **视觉模型** | 任何支持图片输入、兼容 OpenAI 接口的模型：云端 API 或自己部署。 |
| **装了 Xcode 的 Mac** | 只在刷板子、编译 App 时用一次，运行时不需要。 |

## 快速开始

### 1. 刷板子（插在 Mac 上）

安装 [arduino-cli](https://arduino.github.io/arduino-cli/)、ESP32 core 3.3.x 和 NimBLE-Arduino 2.5.x，然后：

```bash
arduino-cli lib install "NimBLE-Arduino@2.5.1"
hardware/flash.sh            # 可选参数：[串口] [--debug]
```

一定要用 `flash.sh` 编译：它会带上 `hardware/hid_bridge/nimble_cfg.h` 里的蓝牙缓冲区配置。

### 2. 安装 App

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig   # 填 DEVELOPMENT_TEAM 和 IA_BUNDLE_ID
open ios/IPhoneAgent.xcodeproj                                    # 在 iPhone 上运行 IPhoneAgent scheme
```

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `ios/project.yml` 生成（`cd ios && xcodegen`）。免费 Apple ID 就能签名（每 7 天重签一次）。一键加入热点需要 Hotspot Configuration 能力（付费账号）；没有的话 App 会显示热点密码让你手动加入。

### 3. 首次设置（在 App 里）

把板子插到 iPhone 上，打开 **ESP32 Agent**。引导共四步，每一步 App 自己检测：

1. **Plug Me In**：蓝牙配对板子。
2. **Let Me See the Screen**：加入板子的 Wi-Fi，然后 控制中心 → 屏幕镜像 → *ESP32 Agent*。
3. **Let Me Use the Pointer**：打开辅助触控，App 自动校准指针。
4. **Give Me a Brain**：填模型地址和密钥（存在钥匙串里）。

### 4. 给它一个任务

输入目标（比如 *"打开设置，进入无线局域网"*），点 **Start**。可以从灵动岛停止，或回到 App 停止。Siri、快捷指令、小组件和控制中心可以运行保存的任务。

## 模型和提示词

- 任何兼容 OpenAI 接口的视觉模型都能用（vLLM、SGLang、llama.cpp、Ollama、云端 API）。App 会列出接口上的模型并自动选择，也可以手动指定，规划器和执行器可以用不同模型。
- 提示词是 [`prompts/`](prompts/) 里的纯文本，打包进 App：改完重新编译即可。
- 开发时用的是 [nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4)，部署在两台 DGX Spark 上（[TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold)）。

## 目录结构

```
ios/        App（SwiftUI）：蓝牙连接、H.264 解码、Agent、引导、回放、实时活动、小组件；单元测试
prompts/    App 用的规划器 / 执行器提示词
hardware/   ESP32-S3 固件（Arduino）：蓝牙 GATT、热点、AirPlay 接收端、USB HID；刷写脚本、
            主机测试、Mac 蓝牙调试工具（hardware/tools）
docs/       蓝牙协议、旧版说明
server/     旧版 v0.1.0 的电脑端服务，新版不使用（见 server/README.md）
```

不用手机 App 调试：`hardware/tools/board_test.py` 在 Mac 上通过蓝牙扮演 App（[hardware/tools/README.md](hardware/tools/README.md)）。板子与 App 的协议：[docs/ble-protocol.md](docs/ble-protocol.md)。

## 路线图

- [x] 去掉电脑：板子负责镜像和点击，手机上的 App 负责思考
- [ ] 横屏 App（坐标和校准目前按竖屏）
- [ ] 非 ASCII 输入（比如用 iOS 拼音键盘输入中文）
- [ ] 更快：一次模型调用多个动作，只在需要时校正指针
- [ ] 在 iOS App 内整理一份效果最好的模型推荐列表（[@asharthinks 的建议](https://x.com/asharthinks/status/2110740775030125019)）

## 限制

- 蓝牙约 300-500 kbps，所以镜像画面很小（480×1040，≤5 fps）；每一步要几秒，主要花在模型上。
- iOS 不镜像部分界面（输入密码、Apple Pay、DRM 视频），Agent 看不到。手机锁屏后镜像会停止。
- Agent 运行时，手机的 Wi-Fi 是板子的热点（没有外网），模型走蜂窝数据。
- App 用 iOS 私有 API（`suspend`）退出自己；自己编译的版本没问题，上架前会替换。
- 键盘输入只支持 ASCII。暂不支持横屏 App。

## 负责任地使用

只自动化你拥有或有权使用的设备和账号，遵守相关 App 的条款。Agent 是在用你的手操作：看着它，随时准备停止。

## 参与贡献

欢迎提 Issue 和 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题：[SECURITY.md](SECURITY.md)。

## 相关项目

| 项目 | 方式 | 与本项目的区别 |
|---|---|---|
| [VersaiOS](https://github.com/zhaodashuaibi/VersaiOS) | UxPlay 镜像 + ESP32-S3 蓝牙鼠标 + 视觉模型 | 需要电脑；一条指令一次点击 |
| [ja1chen/actell](https://github.com/ja1chen/actell) | iPhone 上的 Agent App，走 Apple CoreDevice 调试通道 | 需要开发者模式和开发者磁盘映像 |
| [AidenAI-IO/aiden-firmware](https://github.com/AidenAI-IO/aiden-firmware) | HDMI 采集 + USB 键鼠 + 多模态模型 | 需要采集硬件；主要面向 Android |
| [yoyicue/glassbox](https://github.com/yoyicue/glassbox) | PicoKVM HDMI 采集 + USB HID | 需要 macOS 控制端和 PicoKVM |
| [boboabw/phone-agent](https://github.com/boboabw/phone-agent) | ESP32-S3 蓝牙 HID + 辅助触控，Agent 是 iPhone App | 最接近新版；本项目还把"眼睛"也放进了板子（AirPlay） |
| [VKCOM/devicehub](https://github.com/VKCOM/devicehub) | ESP32 蓝牙鼠标，用于 iOS 设备农场 | 设备农场工具，没有 AI Agent |

基于 WebDriverAgent/XCUITest 的工具，如 [mobile-mcp](https://github.com/mobile-next/mobile-mcp) 和 [Midscene](https://github.com/web-infra-dev/midscene)，需要 Mac 和代码签名。

## 致谢

[UxPlay](https://github.com/FDH2/UxPlay)（固件里的 AirPlay 接收端移植自它）·
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) ·
[Arduino ESP32 core](https://github.com/espressif/arduino-esp32) 和 [TinyUSB](https://github.com/hathach/tinyusb)

## 许可证

[MIT](LICENSE)；`hardware/hid_bridge/src/airplay/`（移植自 UxPlay）除外，为 [GPL-3.0](hardware/hid_bridge/src/airplay/LICENSE-GPL.md)，因此链接了它的固件二进制按 GPL-3.0 分发。
