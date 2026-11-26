# Harness：不接线，在测试用 iPhone 和板子上开发

[English](README.md) · 简体中文

```
Mac ──Wi-Fi (devicectl)── iPhone（App 的 Debug 构建）──USB── 板子（HID、供电）
                              └──── BLE + Wi-Fi :7300 OTA ──────── 板子

harness/app.sh          构建 + 安装 + 启动 App
harness/fw.sh           构建固件，复制进 App，由 App 安装到板子上
harness/run.sh "<task>" 在 App 里开始一个任务，打印它怎么结束的
harness/logs.sh         App 的 debug.log（加 --runs 带运行轨迹）
harness/hid.sh "…"      通过 App 发原始板子命令（key、type、move……），以及 shot / gop / video-reconnect
harness/board.py        只用一次：让板子连上 Mac 的 Wi-Fi（net sta | net ap）
harness/tapcv.py        没有镜像也能点：截图、找指针、修正、点击、检查（uv run）
```

所有操作都通过 `devicectl` 经 Wi-Fi 发到 iPhone。设置完成后 Mac 不再直接和板子通信：App 连着时，板子的 App 连接只属于 App，所以固件走 Mac → App → 板子，和「更新板子」的路径一样。板子以 station 方式（`net sta`）加入 Mac 的 Wi-Fi，而不是打开自己的热点，这样 iPhone 一直留在 Mac 的网络里，也能在这个网络里连到板子。

## 一次性设置

1. **iPhone**：打开开发者模式，和这台 Mac 配对（Xcode › Devices，勾选「Connect via network」），连在 Mac 的 Wi-Fi 上。`export HARNESS_IPHONE=<xcrun devicectl list devices 里的名称或 ID>`。App 的 bundle id 从上一次 `harness/app.sh` 构建中读取；要用别的就设置 `HARNESS_BUNDLE`。
2. **Lightning iPhone**：板子需要 USB 主机口。用 Apple 的 Lightning 转 USB 3 相机转换器，配一根 USB-A → USB-C **数据**线接板子，再在转换器的 Lightning 口接充电器（给 iPhone 和板子供电）。USB-C iPhone 直接插板子即可。
3. **让板子连上 Mac 的 Wi-Fi**（只此一次，Mac 走 BLE）：在 iPhone 上退出 App，重新插拔板子，三分钟内（新的 BLE 设备只能在这段时间配对）运行 `uv run harness/board.py net sta`，并接受 macOS 的配对弹窗。SSID 和密码在 macOS 对话框里输入，只经加密连接发给板子。`net ap` 切回热点。然后重新打开 App。
4. 在 iPhone 上重新把屏幕镜像到「ESP32 Agent」（控制中心 › 屏幕镜像）。

## 日常循环

```bash
harness/app.sh                     # 构建 + 安装 + 启动 Debug 版 App（Wi-Fi）
harness/fw.sh                      # 构建并通过 App 更新板子；"harness ota: done fw v0.2.1 up …"
harness/run.sh "Open Settings"     # 跑一个任务，打印 "finished: …"
harness/logs.sh [--runs]           # 把日志（和运行轨迹）复制到 /tmp/harness-logs/
harness/fw.sh --corrupt            # 检查：App 拒绝损坏的镜像，板子继续运行
harness/fw.sh --crash-test         # 检查：会崩溃的镜像（9.9.9）会回滚；"failed … went back …"
harness/fw.sh --small-gop          # 测试构建：256 KB 的 GOP，几分钟就会填满（之后再运行一次 fw.sh）
harness/hid.sh "key ctrl+space; type abc; shot"   # 给前台 App 发按键；shot → /tmp/harness-shots/
harness/hid.sh "gop; video-reconnect; shot"       # 填满 GOP，再断开 Wi-Fi 视频：画面必须恢复实时
```

这些脚本把参数写成 `Documents/developer/harness-inbox/<time>.json` 交给 App（Debug 构建每秒读一次），并把 App 调到前台。直接用启动参数会丢：板子重连后，iOS 会为了蓝牙在后台恢复 App，这时 `devicectl` 的启动只会把那个进程带到前台。

板子重启后（每次 `fw.sh`），以及板子的 GOP 缓冲已满时运行 `app.sh` 之后（新的 App 进程需要关键帧，而 iOS 只在开始镜像时发送），都要在 iPhone 上重新选择屏幕镜像。同一个 App 进程内的 Wi-Fi 视频重连会自动恢复，不需要任何操作。

`fw.sh` 把镜像和一个 `firmware.json`（大小、SHA-256、MD5，版本取自 `hardware/hid_bridge/version.h`）复制到 `Documents/developer/harness-fw-<time>/`（每次一个新目录：`devicectl` 不会替换它之前复制过的文件；千万不要传 `--remove-existing-content`，它会清空整个 App 容器），然后把 `-harness-ota <folder>` 交给 App，并跟踪它的日志直到出现结果行（最多 3 分钟）。

## 没有镜像时点击（tapcv.py）

镜像关了或卡住（新的 App 进程要等镜像重新开始才拿得到关键帧）时，Agent 看不到屏幕，但板子还能移动指针。`tapcv.py` 在 Mac 上做闭环：把指针推到左上角，按标定的单位移动，在截图里找到灰色的指针圆点（和移动前那张截图的差异），修正到 14 px 以内再点击，然后检查屏幕变了（`--expect TEXT`：这段文字出现了）。比例按屏幕尺寸学习，存在 `~/.cache/harness-tapcv.json`。

```bash
export HARNESS_SHOT=<把截图写到指定路径的命令>   # 例如 pymobiledevice3 developer dvt screenshot --userspace
export HARNESS_OCR=<对一张图输出 [{"text","x","y","w","h"}] 的命令>
uv run harness/tapcv.py tap-text Settings --expect General
uv run harness/tapcv.py mirror <板子名> --restart    # 控制中心 › 屏幕镜像 › 这块板子，直到连上
```

设置了 `HARNESS_BOARD`（板子名）时，`run.sh` 在任务开始前发现没有画面会自己做这一步。

装了 pymobiledevice3 时（`HARNESS_PMD3`，否则从 PATH 找；手机连 USB），进出 App 的文件（日志、命令、截图）走 `pymobiledevice3 apps afc`，每个文件约 1.5 秒；devicectl 在任务和镜像同时进行时可能要 40 秒甚至失败。没装就用 devicectl。

`hid.sh "...; stay"` 让指针留在移动到的位置（否则结束时回到角落）。

## 安全

- **`-harness-ota`** 和经板子转发的 App 命令只存在于 **Debug 构建**；商店版会忽略它们。只有 Debug 构建里，固件清单可以不签名，或者是板子已经在运行的版本；大小、SHA-256 和 MD5 仍然必须匹配。商店版和以前一样只安装签名的正式版本。
- **固件更新**需要板子每次启动生成的令牌（只有已连接的 App 或 USB 串口能读到），外加镜像的 MD5。网络上没有新增监听端口。
- **新的 BLE 设备**只能在板子上电后的 3 分钟内配对（`ble_link.cpp`，`PAIR_WINDOW_MS`）。
- **Wi-Fi 密码**在 macOS 对话框里输入，只经加密连接发送，不会在 Mac 上记录或保存；板子把它和热点凭据一样存在 NVS 里。
- 仓库里没有设备名、SSID 或 ID：它们来自环境变量（`HARNESS_IPHONE`）或对话框。
- 板子不校验签名（正式版由 App 校验）；请让它待在可信网络里，开发之外的时间用 `net ap`。
