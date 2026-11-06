# 在 Mac 上测试板子

[English](README.md) · 简体中文

`board_test.py` 通过 BLE 扮演 iOS App（docs/ble-protocol.md），并读取 BLE 的 `video` 特征值。iPhone App 的视频走 Wi-Fi TCP（端口 7201）。**AirPlay 源必须是 iPhone。** 不支持从 macOS 屏幕镜像：握手看起来可能正常，但板子始终收不到视频。需要 `uv`、装好 esp32 core 3.3.x 的 `arduino-cli`、`ffmpeg`，以及 BLE 主机库（装一次）：`arduino-cli lib install "NimBLE-Arduino"`（2.5.x）。请始终用 `hardware/flash.sh` 构建：它会强制包含 `hid_bridge/nimble_cfg.h`（NimBLE 缓冲区大小）；直接用 IDE 构建会在 static_assert 处失败。

## 1. 刷测试版固件（板子插在 Mac 上）

```bash
cp hardware/hid_bridge/secrets.example.h hardware/hid_bridge/secrets.h   # 只需一次；填入 Mac 所在的 Wi-Fi
hardware/flash.sh --sta --debug    # 加入这个 Wi-Fi，而不是打开自己的热点；日志走 USB 串口
```
查看日志（AirPlay 握手步骤、启动时的 heap/PSRAM 行）：
```bash
arduino-cli monitor -p /dev/cu.usbmodem* -c baudrate=115200
```
不加 `--sta` 时，板子会打开自己的热点 `ESP32Agent-XXXX`（密码：用下面的 `net` 读取）；Mac 也可以改连这个热点，但那样就没有外网了。

## 2. 只测 BLE（还没有镜像）

```bash
uv run hardware/tools/board_test.py info        # 配对（macOS 会弹窗）、读取 `net`、打印状态
uv run hardware/tools/board_test.py bench --kb 512
uv run hardware/tools/board_test.py hid         # 移动/点击 Mac 的指针：板子是一个 USB 鼠标
uv run hardware/tools/board_test.py stress --seconds 20 --kb 512   # bench 填充 + 每 200 ms 一次 ping/move
```
`stress` 会打印回复延迟的 p50/p95/max 和丢失的回复（目标：0 丢失，p95 < 500 ms）；`--load stream` 改用 `stream on`（需要镜像）。Mac 只能收到约 100–200 kbps，测吞吐量请用 iPhone：用 `--debug` 构建后，在 USB 串口发送 `N bench 512`；结果会回显为 `video: N ok <ms>`（kbps = 512*8*1024/ms）。对比射频设置：在串口发送 `N coex bt|balance|wifi`，以及对比 `hardware/flash.sh --ap-tune`（20 MHz 热点、300 TU 信标）和普通构建。输出里的 `net` 密码会被遮住。

## 3. AirPlay -> BLE

1. 在 iPhone 上：控制中心 -> 屏幕镜像 -> **ESP32 Agent**（手机必须和板子在同一个 Wi-Fi）。不支持从 macOS 屏幕镜像。串口日志应该依次出现 `GET /info`、`pair-setup`、`pair-verify 1/2`、`fp-setup 1/2`、`setup: mirror stream`、`mirror: data connection accepted`、`mirror: SPS ... PPS`。
2. 然后：
```bash
uv run hardware/tools/board_test.py snap        # -> hardware/tools/out/snap.h264 + snap.png（截图延迟）
uv run hardware/tools/board_test.py stream --seconds 20   # -> out/stream.h264 + stream.png、kbps、间隔
uv run hardware/tools/board_test.py all         # info、bench、snap、stream、hid、status
uv run hardware/tools/board_test.py cmd "res 480 1040" "fps 5"   # 任意命令行
```
`ffplay hardware/tools/out/stream.h264` 可以播放视频流。

## 4. 回到 iPhone

不加 `--sta` 重新刷（`hardware/flash.sh`），再把板子插回 iPhone。

## 待办 / 下一步优化（2026-10-15 实测，NimBLE-Arduino 2.5.1，板子接 Mac + iPhone App 已连接）

- 吞吐量和延迟：只有 msys 预留门限时，经串口对 iPhone 测 `bench 512` 约 381 kbps（balance）、约 412（`coex bt`）、约 364（`coex wifi`）；连接间隔改成 30 ms 后减半（180 kbps）。加上命令期间的控制器信用上限（VIDEO_CTRL_PKTS = 8，CMD_ACTIVE_MS = 1000）后约 130–170 kbps，因为 App 的定期 ping 让上限一直生效。Mac 压测（bench 负载，每 200 ms ping/move）：0 丢失，p50 33–66 ms，p95 83–156 ms，max 93–262 ms（加上限之前：p95 0.96–2.2 s）。下一步：按连接而不是全局设上限，在 iPhone 上调 VIDEO_CTRL_PKTS/CMD_ACTIVE_MS，或者判断「命令在发」时忽略 App 的保活 ping。
- 用 L2CAP CoC 传视频（已配置 1 个 247 MPS 通道，还没用上）。
- 在 iPhone 上开着镜像做共存 A/B（`coex`、`--ap-tune`）；还没在 AirPlay 运行时测过。
- 视频流：仅 IDR 的回退（跳过超过 800 ms 的 P 帧）还没在实时镜像下验证过（`board_test.py stress --load stream`）。
