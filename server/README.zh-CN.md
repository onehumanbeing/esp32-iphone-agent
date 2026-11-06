# server/（旧版）

[English](README.md) · 简体中文

这是最初版本（tag `v0.1.0`，分支 `legacy`）的电脑端服务器：Mac 或 Linux 电脑上的 UxPlay 接收屏幕，这个 Python 服务器运行 Agent 和网页界面，ESP32 只是一个通过 Wi-Fi 连接它的 USB 鼠标。

**当前版本不使用它。** 现在由板子自己接收 AirPlay，Agent 运行在 iPhone App 里（`ios/`），提示词在 `prompts/`。保留这个目录是为了让旧版方案继续可用、测试继续在 CI 里跑；它只接受修复，不再加新功能。它的提示词是 `hidagent/agent.py` 里的旧版本，不和 `prompts/` 同步。

注意：当前固件通过 BLE 收发命令和状态，而不是这个服务器使用的 TCP 行协议。发给 App 的视频是另一条 Wi-Fi TCP 通道（端口 7201）。要运行旧版方案，请检出 `legacy`（或 `v0.1.0`），按那里的 README 操作。
