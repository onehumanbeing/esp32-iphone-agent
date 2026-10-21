<div align="center">

# ESP32 iPhone Agent

**让 AI 操作一部真实的 iPhone：只要一块约 40 多元的 ESP32，不需要开发者账号、不需要 Xcode、不用越狱。**

[English](README.md) · 简体中文

演示视频和更新：[X @iamhenryyuan](https://x.com/iamhenryyuan) · [小红书 袁老板讲黑客松（Henry）](https://www.xiaohongshu.com/user/profile/5eb444030000000001000194) · [YouTube 演示](https://www.youtube.com/watch?v=Ly4im-P4jYg)

[![CI](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Python](https://img.shields.io/badge/python-3.10%2B-blue)
![Board](https://img.shields.io/badge/board-ESP32--S3-red)

</div>

<p align="center"><img src="docs/images/demo.png" alt="示例 1：在白板里画完笑脸后的网页界面，包括实时画面、实时日志、计划和每一步的截图" width="100%"></p>

**示例 1：在画布上画画。** *"打开白板画一个笑脸"*：Agent 搜索并打开白板 App，用连续的笔画画出笑脸。每一步的截图都会留在截图墙上，上面画出了点按或笔画的位置。

<p align="center"><img src="docs/images/example-alarm.png" alt="示例 2：插着 XIAO ESP32S3 的 iPhone 正在设置每天重复的闹钟，旁边是网页界面" width="100%"></p>

**示例 2：设置闹钟。** *"设置早上 7:00 的闹钟，每天重复，然后保存"*：Agent 打开时钟，在时间滚轮里直接输入 0700，在「重复」里一次连续勾选多天，然后保存。左边是插着 ESP32 的真实 iPhone，右边是网页界面。

Agent 通过 AirPlay 屏幕镜像"看"手机，通过一块插在手机 USB 口上的 ESP32-S3 小板子"摸"手机：板子对手机来说就是一个
USB 鼠标加键盘。大脑可以是任何兼容 OpenAI 接口的视觉模型，云端 API 或自己部署的模型都行。

## 为什么做这个

大多数 iPhone 自动化方案通过 XCTest / WebDriverAgent 控制手机，需要 Mac、Xcode、一个签过名的辅助 App，还要 Apple
开发者账号（免费账号的签名 7 天就过期）。本项目走的是人用手机的路径：看屏幕、动指针，所以手机上什么都不用装。

|                          | ESP32 iPhone Agent     | XCTest / WebDriverAgent 类工具 |
|--------------------------|------------------------|--------------------------------|
| Apple 开发者账号         | **不需要**             | 需要（给测试程序签名）         |
| Xcode                    | **不需要**             | 需要                           |
| 电脑                     | Mac、Linux **或 Windows** | Mac                            |
| 手机上安装 App           | **不需要**             | 需要装测试程序                 |
| 越狱                     | 不需要                 | 不需要                         |
| 额外硬件                 | ESP32-S3 开发板（约 40 多元） | USB 线                    |
| 任意 App（包括游戏）     | 可以（只看像素）       | 大多可以（取决于无障碍控件树） |

## 工作原理

- **眼：AirPlay 镜像。** 手机把屏幕镜像到电脑上运行的 [UxPlay](https://github.com/FDH2/UxPlay)，GStreamer 把视频流
  转成一帧帧 JPEG，供 Agent 和网页使用。
- **手：USB HID 桥。** 插在手机上的 ESP32-S3 被识别为标准的 USB 鼠标和键盘。打开 iOS 的辅助触控（AssistiveTouch）后，
  鼠标会控制屏幕上的一个指针：点击就是点按，拖动就是滑动。板子通过 Wi-Fi 连接电脑，只执行简单的行命令
  （`move`、`click`、`type` 等），所有逻辑都在电脑上。
- **脑：规划模型 + 执行模型。** 规划模型根据目标和当前屏幕写一个简短的计划；执行模型每次看最新截图，选出下一个动作：
  点按、滑动、画一笔、输入、按键、回主屏幕或结束。两个角色可以用同一个模型。
- **闭环校验。** 鼠标是相对移动的，所以服务端会记录指针位置。每次点按前，它会轻推一下指针，在镜像画面里找到它的真实位置，
  偏了就先纠正，同时修正校准。每个动作之后检查屏幕是否真的变化了，并告诉模型。点空了会被发现并重试，而不是将错就错。
  同一个动作重复多次会触发重新规划；断线或模型回复出错都能自动恢复。

## 硬件

| 部件 | 说明 |
|---|---|
| **ESP32-S3 开发板** | 实测使用 [Seeed Studio XIAO ESP32S3](https://wiki.seeedstudio.com/cn/xiao_esp32s3_getting_started/) 普通版、未焊排针（不是带摄像头的 Sense 版，也不是 Plus 版）。国内在淘宝搜“XIAO ESP32S3”就能买到，约 40 多元。任何 USB-C 口直连 S3 原生 USB 的 ESP32-S3 板子都可以。 |
| **iPhone** | USB-C 机型直接插；Lightning 机型用 Lightning 转 USB 相机转换器。板子由手机供电。 |
| **电脑** | macOS、Linux 或 Windows，和手机在同一个局域网；运行 UxPlay 和服务端。 |
| **视觉模型** | 任何支持图片输入、兼容 OpenAI 接口的对话模型。本地部署是可选的。 |

<p align="center"><img src="docs/images/setup.png" alt="插在 iPhone 上的 XIAO ESP32S3，旁边是网页界面" width="100%"></p>

如果希望插着板子时手机还能充电，用一个支持 PD 充电直通的 USB-C 扩展坞。

## 快速开始

> **让 AI 编程助手帮你装。** 在板子要连接的那台电脑上，把下面这段话发给 Claude Code、Codex 或类似的 Agent：
>
> ```text
> Clone https://github.com/onehumanbeing/esp32-iphone-agent and follow its README to set it up on this machine:
> flash the ESP32-S3 plugged in over USB, install UxPlay and the server, write server/.env for my model API, start
> the server and give me the web UI address. Ask me for the Wi-Fi name/password and the model API key.
> ```

### 1. 刷固件

安装 [arduino-cli](https://arduino.github.io/arduino-cli/) 和 ESP32 core（3.x），然后：

```bash
cp hardware/hid_bridge/secrets.example.h hardware/hid_bridge/secrets.h
# 编辑 secrets.h：填 2.4 GHz Wi-Fi 名称和密码，以及运行服务端的电脑的 IP
hardware/flash.sh            # 可选参数：[串口] [--debug]
```

### 2. 安装并启动服务端

```bash
# UxPlay，macOS：
brew install uxplay
# UxPlay，Debian / Ubuntu：
sudo apt install uxplay gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav

cd server
python3 -m venv .venv && .venv/bin/pip install -e .
cp .env.example .env         # 填 LLM_BASE_URL / LLM_MODEL / LLM_API_KEY
set -a && . ./.env && set +a && .venv/bin/python -m hidagent
```

如果想在重启服务端（比如改完代码）时不断开手机的屏幕镜像，可以在另一个终端里单独运行 AirPlay 接收端，
让服务端去读它的画面（两条命令都在 `server/` 下运行）：

```bash
set -a && . ./.env && set +a && .venv/bin/python -m hidagent.receiver                          # 只需一次，保持运行
set -a && . ./.env && set +a && MIRROR_STREAM=127.0.0.1:8891 .venv/bin/python -m hidagent      # 可以随便重启
```

浏览器打开 `http://127.0.0.1:8890`。服务端没有密码，所以默认只监听本机；设置 `HOST=0.0.0.0` 才会对局域网开放。

### Windows

上面的命令都在 **Git Bash**（Git for Windows 自带）里运行。`hardware/flash.sh` 会自己找到板子的 COM 口，也可以手动指定：
`hardware/flash.sh COM5`。服务端：

- 按 [UxPlay 的 Windows 说明](https://github.com/FDH2/UxPlay#building-uxplay-on-microsoft-windows-using-msys2-with-the-mingw-64-compiler)
  用 MSYS2（UCRT64）编译 `uxplay.exe`，并安装 `gst-plugins-good`、`gst-plugins-bad`、`gst-libav`。UxPlay 1.74 起自带 mDNS，
  更早的版本需要 Apple 的 Bonjour。
- 在 Windows 防火墙里放行 `uxplay.exe` 和 Python（手机连 UxPlay，板子连 7300 端口）。
- 在 `.env` 里用 `UXPLAY` 指向 UxPlay，并把 `.venv/bin/` 换成 `.venv/Scripts/`：

```bash
cd server
python -m venv .venv && .venv/Scripts/pip install -e .
cp .env.example .env         # 另外设置 UXPLAY=C:/msys64/ucrt64/bin/uxplay.exe
set -a && . ./.env && set +a && .venv/Scripts/python -m hidagent
```

Windows 上不能输入 ASCII 以外的文字（比如中文）：这要靠“通用剪贴板”，只有 Mac 才有。

### 3. 设置手机（只需一次）

1. **设置 → 辅助功能 → 触控 → 辅助触控**：打开。
2. 把板子插到手机上，屏幕上会出现一个圆形指针，网页显示控制器已连接。
3. **控制中心 → 屏幕镜像 → iPhone Agent**，网页里出现实时画面。
4. 在网页里打开 **手动操控 → 校准**。服务端会移动指针、在实时画面里找到它，几秒内自动完成校准；
   如果找不到指针，会提示你在画面里精确点一下指针。

### 4. 下达任务

输入一个目标（例如"打开设置，进入 Wi-Fi"），点 **开始**；也可以直接点下面的示例。

## 网页界面

- **实时手机画面**：点击 = 点按，拖动 = 滑动，滚轮 = 滚动；也可以手动回主屏幕、返回、输入文字和按键。
- **实时日志**：每一个计划、思考和动作实时显示，带耗时。
- **步骤截图墙**：每一步模型做决定时看到的截图，上面画出点按或滑动的位置，附带模型的理由和思考、执行各用了多久；
  点卡片可以放大。
- **点按**用红色圆圈和扩散的波纹标出，滑动和笔画用黄色轨迹；**动效**开关可以关掉动画。模型标为 `precise`（点之前先确认指针位置）的点按会在日志里注明。
- **紧急停止**（或按 <kbd>Esc</kbd>）：立即停止 Agent 并松开指针。**清空记录**：清空日志和截图墙。
- 界面支持英文和简体中文。

## 配置

写在 `server/.env` 里（参考 [`.env.example`](server/.env.example)）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `LLM_BASE_URL` | `http://localhost:8000/v1` | 兼容 OpenAI 的接口地址 |
| `LLM_MODEL` / `LLM_API_KEY` | — | 模型名称和 API Key |
| `LLM_EXTRA_BODY` | `{}` | 合并进每次请求的 JSON（例如关闭模型的思考模式） |
| `LLM_TOKEN_PARAM` | `auto` | 输出长度参数名：`max_tokens`、`max_completion_tokens`（新版 OpenAI 模型），或 `auto` 自动识别 |
| `ACTOR_*` / `PLANNER_*` | — | 单独覆盖执行模型 / 规划模型的任意 `LLM_*` 配置 |
| `AIRPLAY_NAME` | `iPhone Agent` | 手机"屏幕镜像"列表里显示的名字 |
| `HOST` | `127.0.0.1` | 网页和 API 监听的地址（`0.0.0.0` 对局域网开放，且没有密码） |
| `PORT` / `DEVICE_PORT` | `8890` / `7300` | 网页端口 / 板子连接的端口 |
| `UXPLAY` | `uxplay` | UxPlay 可执行文件（Windows 上如 `C:/msys64/ucrt64/bin/uxplay.exe`） |
| `MIRROR_STREAM` / `MIRROR_PORT` | — / `8891` | 读取单独运行的接收端的画面（`127.0.0.1:8891`，见上文），不再由服务端自己启动 UxPlay / 接收端提供画面的端口 |
| `HIDAGENT_DATA` | `~/.hidagent` | 校准数据和调试记录 |
| `HIDAGENT_DEBUG` | `0` | 调试模式，见下文 |

### 本地模型（可选）

用云端 API 就够了。如果想全部跑在自己的硬件上，下面是本项目开发和测速时用的配置：

- 模型：[nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4)
- 部署：[Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold)，
  两台 NVIDIA DGX Spark 张量并行（TP=2），提供 OpenAI 兼容接口
- 速度：关闭思考模式后，每个动作约 1.3 秒，每次规划约 2 秒：

```bash
LLM_BASE_URL=http://<dgx-spark-ip>:8888/v1
LLM_MODEL=Qwen3.8-Flash-Next
LLM_EXTRA_BODY='{"chat_template_kwargs": {"enable_thinking": false}}'
```

其他兼容 OpenAI 接口的服务（vLLM、SGLang、llama.cpp、Ollama 等）配上视觉模型，用法完全一样。

## 调试模式

设置 `HIDAGENT_DEBUG=1` 后，每条板子命令及其耗时都会写进日志，每次 Agent 运行会单独保存一个文件夹：

```
~/.hidagent/traces/20261012-005207/
├── steps.jsonl   # 每次模型调用（提示词、原始回复、耗时）和每个动作
├── 002.jpg       # 每次模型调用看到的截图
└── ...
```

`hardware/flash.sh --debug` 会编译一个调试版固件，通过 USB 串口回显每条命令和耗时。

## 板子协议

板子本身不含任何逻辑。连上时先发送 `hello <上次重启原因> <开机毫秒数>`，之后服务端通过 TCP 每行发一条命令，板子回复 `ok` 或 `err <原因>`。

| 命令 | 作用 |
|---|---|
| `ping` | 健康检查 |
| `home` | 把指针推到左上角（一个已知位置） |
| `move <dx> <dy>` | 相对移动指针，匀速移动，让 iOS 的指针加速度可预测 |
| `press` / `release` / `click` | 左键按下 / 松开 / 点击 |
| `scroll <v> <h>` | 滚轮 |
| `type <text>` | 输入 ASCII 文字 |
| `key <combo>` | 按键，例如 `enter`、`cmd+h`、`cmd+space` |

Wi-Fi 断开时，板子会松开所有按键并自动重连。手机锁屏时 USB 会休眠：板子会先尝试唤醒手机，唤醒不了就立刻回复 `err phone usb asleep`，不会卡住等待。万一板子没有响应，看门狗会让它自动重启。

## 目录结构

```
hardware/   ESP32-S3 固件（Arduino）和刷写脚本
server/     Agent、网页界面、屏幕采集和板子连接（Python，FastAPI）
            serve/：可选的极简服务，用来自己部署 Hugging Face 视觉模型
```

## 路线图

- [ ] 测试基于 DiffusionGemma 的纯本地方案（`server/serve/` 里有实验性的 OpenAI 兼容服务）
- [ ] 支持横屏 App（目前坐标和校准都按竖屏计算）
- [ ] 非 ASCII 文字输入（例如通过 iOS 拼音键盘输入中文）
- [ ] 更多常用 App 的示例任务

### 探索方向：把电脑也去掉

现在板子只负责"手"，"大脑"和"眼睛"都在另一台电脑上。

下一步想把电脑也去掉：把 ESP32 换成能跑 Linux 的小板子，看屏幕、做决策、点按全在板子上完成。手机只需要接这一块板子，放兜里就能带走。板子和手机之间可以走 USB 或蓝牙，模型可以用本地的，也可以用云端的。

这些是探索方向，不是承诺。感兴趣或者做过类似尝试的，欢迎开 issue 聊。

## 限制

- iOS 不镜像部分界面（输入密码、Apple Pay、有版权保护的视频），Agent 看不到这些画面。
- 手机锁屏后镜像会断开，Agent 工作时请关闭自动锁定。
- 板子只能逐键输入 ASCII。中文等其他文字通过“通用剪贴板”粘贴，需要服务端跑在登录了手机同一 Apple 账户、开启“接力”的 Mac 上；Linux 和 Windows 上只能输入 ASCII。
- 修改辅助触控的跟踪速度后需要重新校准。
- 暂不支持横屏 App：在横屏界面里的点按和绘图位置会偏。
- 在有多个网卡的 Linux 机器上，如果手机列表里看不到接收端，把 Avahi（mDNS）限制在手机所在网络的网卡上。

## 合理使用

只自动化你自己拥有或被允许使用的设备和账号，并遵守相关 App 的条款。Agent 是在替你动手：请看着它，紧急停止按钮随时备好。

## 参与贡献

欢迎提 Issue 和 Pull Request。提交前请先跑一遍检查：

```bash
cd server && pip install -e ".[dev]" && ruff check . && pytest
```

## 相关项目

其他用代码或 AI 操作 iPhone 的方案，以及与本项目的区别。如有错误欢迎指正。

| 项目 | 做法 | 手机 / 主机需要 | 与本项目的区别 |
|---|---|---|---|
| [VersaiOS](https://github.com/zhaodashuaibi/VersaiOS) | UxPlay 镜像 + ESP32-S3 蓝牙鼠标 + 视觉模型 | ESP32 通过 USB 串口连电脑；桌面 GUI，主要是 Windows | 思路最接近。一条指令点一次，没有规划步骤，也不比对前后画面 |
| [ja1chen/actell（执言）](https://github.com/ja1chen/actell) | iPhone 上装 agent App，通过苹果 CoreDevice 调试通道截屏和点按 | 开发者模式、配对 + Developer Disk Image、Xcode 自签 | 本项目不需要开发者模式，不用在手机上装 App，也不用签名 |
| [AidenAI-IO/aiden-firmware](https://github.com/AidenAI-IO/aiden-firmware) | 专用板：HDMI 采集 + USB 键鼠 + 多模态模型 | HDMI 采集芯片和扩展坞；以 Android 为主 | 本项目用 AirPlay 代替 HDMI 采集，不需要采集硬件 |
| [yoyicue/glassbox](https://github.com/yoyicue/glassbox) | PicoKVM HDMI 采集 + USB HID，观察/决策/执行/验证循环 | macOS 控制端和 PicoKVM | 本项目在 Linux 上运行，只要一块 ESP32 |
| [boboabw/phone-agent](https://github.com/boboabw/phone-agent) | ESP32-S3 蓝牙 HID + 辅助触控，agent 是 iPhone App | 需要 Mac + Xcode 编译签名 | 本项目手机上什么都不用装 |
| [dovydaskel/Iphone-control-for-social-media](https://github.com/dovydaskel/Iphone-control-for-social-media) | ESP32 蓝牙鼠标 + OpenCV 指针校正，脚本化发帖 | Mac | 指针闭环思路相近；本项目多了视觉模型的规划/执行 |
| [VKCOM/devicehub](https://github.com/VKCOM/devicehub) | ESP32 蓝牙鼠标，用于 iOS 设备农场 | 设备农场基础设施 | 设备农场工具，没有 AI agent |
| [NolanCotter/AirBridge](https://github.com/NolanCotter/AirBridge) / [gbulog/pcairplay](https://github.com/gbulog/pcairplay) | Linux 上的 UxPlay + 电脑自带蓝牙模拟键鼠 | 带蓝牙的 Linux 电脑 | 人工远程操作，没有 AI |

其他路线：基于 WebDriverAgent/XCUITest 的工具（如 [mobile-mcp](https://github.com/mobile-next/mobile-mcp)、[Midscene](https://github.com/web-infra-dev/midscene)）需要 Mac 和代码签名；基于 macOS iPhone 镜像的工具需要 Mac。

## 致谢

[UxPlay](https://github.com/FDH2/UxPlay)（AirPlay 接收端） ·
[Arduino ESP32 core](https://github.com/espressif/arduino-esp32) 和 [TinyUSB](https://github.com/hathach/tinyusb)（USB HID） ·
[FastAPI](https://fastapi.tiangolo.com/)

## 许可证

[MIT](LICENSE)
