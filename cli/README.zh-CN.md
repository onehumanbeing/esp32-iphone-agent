# esp32agent

[English](README.md) · 简体中文

命令行工具和 MCP 服务器，让电脑（以及电脑上的编程 Agent：Claude Code、Codex）通过 ESP32 Agent 板子看到并操作 iPhone。板子插在 iPhone 上，充当它的 USB 鼠标和键盘，并接收它的 AirPlay 屏幕镜像；电脑通过蓝牙连接板子，两者在同一个网络时改走 Wi-Fi，可以和 iOS App 并用。命令和 JSON 输出格式沿用 [mobilecli](https://github.com/mobile-next/mobilecli)。

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.sh | sh
```

Windows（PowerShell）：`irm https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.ps1 | iex`。
npm：`npm install -g esp32agent`。安装脚本读取 `https://handsy.tech/cli/versions.json` 上的版本列表（读不到时改用 GitHub Releases），并校验压缩包的 SHA-256。截图需要 `ffmpeg`（安装脚本会提示用 brew / apt / dnf / winget 安装）。以后升级：`esp32agent upgrade`。

## 配对

1. 把板子插到 iPhone 上，三分钟内运行 `esp32agent pair`。
2. 在 iPhone 上：控制中心 > 屏幕镜像 > ESP32 Agent。
3. 这时 `esp32agent screenshot` 应该会保存一张手机屏幕的 PNG。

配对由 CLI 自己完成（X25519 密钥交换，之后是 AES-GCM 会话；见 `docs/cli-protocol.md`），不经过操作系统，所以系统里残留的蓝牙配对记录不会有影响。密钥保存在用户配置目录（`~/Library/Application Support/esp32agent`、`~/.config/esp32agent`、`%AppData%\esp32agent`），权限 0600。

## 命令

| 命令 | |
|---|---|
| `devices` | 附近的板子（`id`、`paired`、`connected`） |
| `pair`、`unpair` | 配对这台电脑；在这台电脑上忘掉板子 |
| `screenshot [--format png\|jpeg] [--quality N] [--scale F] [--max-size N] [--output PATH\|DIR/\|-]` | 上一个操作结束、画面稳定后的屏幕；默认保存到当前目录 |
| `io tap X,Y [--aim] [--count N]` | 坐标是原尺寸截图的像素；`--count 2` 双击 |
| `io longpress X,Y [--duration MS]` | |
| `io swipe X1,Y1,X2,Y2` | |
| `io text 'TEXT'` | 仅 ASCII；中文按拼音输入 |
| `io keys COMBO` | `enter`、`esc`、`tab`、`backspace`、`space`、方向键、`cmd+a`、`shift+tab` …… |
| `io button HOME` | 唯一的按键 |
| `screencapture --format h264\|mjpeg` | 实时视频输出到 stdout，例如 `\| ffplay -` |
| `device info` | 板子状态：`ap`（镜像中）、`fz`（画面冻结）、`busy`（App 正在使用手机）、`usb`、`ble` |
| `calibrate` | 测量指针（第一次点按时会自动执行；需要指针可见） |
| `net` | CLI 当前的通道（`via`：`ble` 或 `wifi`）和板子的 Wi-Fi。电脑和板子在同一个网络（同一个 Wi-Fi，或电脑连着板子热点）时，命令和画面走 Wi-Fi，蓝牙作为备用通道 |
| `net join` | 询问 Wi-Fi 名称和密码（密码不回显），通过蓝牙会话发给板子，并等到通道切到 Wi-Fi。`net join SSID [PASSWORD]` 不询问直接设置。iPhone 也通过这个 Wi-Fi 镜像 |
| `net hotspot` | 让板子重新打开自己的热点 |
| `net via auto\|ble` | `ble` 让会话保持走蓝牙（也可以设 `ESP32AGENT_TRANSPORT=ble`） |
| `listen` | 手机最近 30 秒播放的声音（视频、通话、App 语音）转成的文字；听不到时说明原因 |
| `listen on\|off` | 投屏时收听手机声音（默认关，设置会保存） |
| `listen mode phone\|local` | `phone`（默认）：用 ESP32 Agent App 在手机上转好的文字（在 App 里打开 设置 › 收听手机声音 和 分享给电脑）。`local`：通过 Wi-Fi 拿原始音频，在这台电脑上用 whisper.cpp 转文字 |
| `listen lang CODE\|none` | `local` 模式：英语以外的第二语言，如 `zh`（默认跟随这台电脑的语言） |
| `history list`、`history show RUN\|latest`、`history new` | 在手机上做过什么：运行记录（最新的在前，30 条）、某次运行的步骤；开始新的运行 |
| `intent list`、`intent show NAME\|ID` | 保存的意图 |
| `intent save --name N --prompt P [--hint H ...] [--from-run RUN [--steps 1,3,4]]` | 保存意图；步骤取自某次运行中可以重放的操作（全部，或 `history show` 里的编号） |
| `intent delete NAME\|ID` | |
| `intent export NAME\|ID... [--screenshots] [--output FILE]` | 导出 iOS App 能导入的 `.esp32intent` 文件；加 `--screenshots` 才带参考截图 |
| `intent import FILE` | 导入 `.esp32intent` 文件（来自 App 或 `export`）；名称和提示词都相同的已有意图会跳过 |
| `memory list`、`memory search TEXT [--limit N]` | Agent 记住的内容，最相关的在前 |
| `memory add TEXT [--kind preference\|fact\|app] [--topic APP]` | 记住一行；密码、验证码、银行卡号和证件号会被拒绝 |
| `memory rm ID` | |
| `memory export [--output FILE]`、`memory import FILE` | App 的 `MEMORY.md`；导入时 id 或文字相同的条目保留较新的一份 |
| `report --intent NAME [--screenshots]` | 准备一封邮件，把一个意图发给开发者（见下文）；需要交互 |
| `upgrade [--check] [--force]` | 安装最新版本（`--check`：`current`、`latest`、`update_available`） |
| `mcp` | stdio 上的 MCP 服务器 |
| `skill install` | 把 Agent 技能写到 `~/.claude/skills/esp32agent/` |
| `daemon [stop]`、`version` | |

附近有多块板子时，用 `--device <id>`（12 位十六进制 ID，或板子名称里的 4 位十六进制数）指定，或设置 `ESP32AGENT_DEVICE`。输出是 `{"status":"ok","data":...}` 或 `{"status":"error","error":"..."}`（退出码 1）。需要设备端 Agent 的 mobilecli 命令（`apps`、`dump ui`、`fs`、`webview` 等）会返回 `not supported on ESP32 Agent`。

第一个命令会启动后台的 `esp32agent daemon`，由它保持蓝牙会话并解码视频；其他命令通过配置目录里的 unix socket 连接它（日志：同目录下的 `daemon.log`）。空闲 10 分钟后它会自动退出。

## 接入 Agent

```sh
claude mcp add esp32agent -- esp32agent mcp      # Claude Code
codex mcp add esp32agent -- esp32agent mcp       # Codex
esp32agent skill install                         # Claude Code 技能（操作循环、输入规则）
```

MCP 工具：`screenshot`（返回图片）、`tap`、`longpress`、`swipe`、`type_text`、`press_key`、`press_button`、`device_info`，以及 `history`、`intent_list`、`intent_show`、`intent_save`、`memory_recall`、`memory_add`。操作循环是：截图、判断、做一步、再截图，见 [SKILL.md](SKILL.md)。

## 历史记录和意图

daemon 会像 iOS App 记录运行一样，记下每个操作和截图：配置目录里的 `runs/<yyyyMMdd-HHmmss>/steps.jsonl`（操作用 0–1000 的屏幕单位，画面存成 480 像素宽的 JPEG）。空闲 10 分钟后或运行 `history new` 时开始新的一次运行；保留最新的 100 次。所有内容都不会离开这台电脑。

意图是保存下来的任务：名称、提示词、最多 6 条提示，以及录下的步骤和对应画面（配置目录里的 `intents.json` 和 `intent-frames/<id>/`，字段和 App 一致）。`intent save --from-run RUN` 会取这次运行中可以重放的操作（点按、滑动、输入、按键、回主屏幕）。`intent export` 和 `intent import` 使用 App 的 `.esp32intent` 格式，所以意图可以在 CLI 和 iPhone App 之间互传（隔空投送或「文件」App）。

## 记忆

iOS App 把用户告诉它的内容（偏好、事实、某个 App 怎么用）存在 `MEMORY.md` 里，每条一行，上面带日期。CLI 在配置目录的 `memory/MEMORY.md` 里存同一种文件。互传方法：在 App 里点「设置 › 记忆 › ⋯ › 导出 MEMORY.md」（隔空投送或「文件」App），再运行 `esp32agent memory import FILE`；反过来用 `esp32agent memory export`，再在 App 里点「设置 › 记忆 › ⋯ › 导入」。不经过任何服务器。

## 把意图分享给开发者（可选）

`esp32agent report --intent NAME [--screenshots]` 可以帮助大家改进意图。它只能在你亲自输入的终端里运行（Agent 调用不了，也没有对应的 MCP 工具）。它会在临时目录写一个脱敏的 `.esp32intent`：输入过的文字变成 `•••`，IP 地址会被删掉；加 `--screenshots` 时，每张截图顶部 7%（状态栏、通知）会被涂黑，并缩到 480 像素宽，画面上的其他文字仍然看得清。它会先列出文件里的全部内容（名称、提示词、提示、步骤数、截图、路径），你输入 `y` 才会继续：然后在你的邮件 App 里打开一封发给 `intents@handsy.tech` 的邮件，并显示这个文件。附上文件后由你自己发送；esp32agent 不会自己发送任何东西。

## 限制

- iOS App 优先：App 操作手机期间（以及之后 20 秒），指针和键盘命令会失败并返回 `busy: the app is using the phone`。等一会儿再试。
- 走蓝牙时，截图可能比实际画面慢约一秒，动画不连贯；走 Wi-Fi 时几乎实时。
- 点按是相对鼠标移动，从左上角推算位置，每 10 次手势重新归位一次；准确度取决于校准（`calibrate`、`io tap --aim`）。
- 输入仅支持 ASCII（每个字符一次按键）；没有剪贴板，没有音量/电源键，不能安装或直接打开 App。
- 手机声音：只有文字，可能听错。`listen mode local` 需要 Wi-Fi（蓝牙不行）、`brew install whisper-cpp`
  （或 PATH 里有 whisper.cpp 的 `whisper-cli`），以及配置目录 `whisper/` 下的模型 `ggml-base.bin`；
  缺什么 `listen mode local` 会提示。

## 开发

```sh
cd cli && go vet ./... && go test ./...
make -C hardware/tests/sim      # 模拟板子（固件的 cli_link.cpp）：启用集成测试
ESP32AGENT_SIM=$PWD/hardware/tests/sim/cli_sim esp32agent screenshot   # 让 CLI 连模拟器
```

发布：推送 tag `cli-vX.Y.Z`；`.github/workflows/cli.yml` 会为 amd64/arm64 构建 darwin（cgo、CoreBluetooth）、linux 和 windows（纯 Go）版本，并上传压缩包和 `checksums.txt`。它还会生成一个 `versions.json` 产物（[格式](install/versions.example.json)）；把它合并进 `https://handsy.tech/cli/versions.json` 需要手动完成。`ESP32AGENT_VERSIONS_URL` 可以让 `upgrade` 和安装脚本改读另一份列表（用于测试）。测试安装脚本：`ESP32AGENT_ARCHIVE=/path/esp32agent_darwin_arm64.tar.gz sh cli/install/install.sh`（`checksums.txt` 放在同一目录）。
