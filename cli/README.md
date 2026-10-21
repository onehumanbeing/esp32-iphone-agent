# esp32agent

Command line and MCP server that let a computer (and the coding agent on it: Claude Code, Codex) see and drive an
iPhone through an ESP32 Agent board. The board is plugged into the iPhone as its USB mouse and keyboard and receives
its AirPlay screen mirroring; the computer reaches it over Bluetooth, next to the iOS app. Commands and JSON output
follow [mobilecli](https://github.com/mobile-next/mobilecli).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.sh | sh
```

Windows (PowerShell): `irm https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.ps1 | iex`.
npm: `npm install -g esp32agent`. All three download a release binary and check its SHA-256 against
`checksums.txt`. Screenshots need `ffmpeg` (the installers offer brew / apt / dnf / winget).

## Pair

1. Plug the board into the iPhone. Within 3 minutes: `esp32agent pair`.
2. On the iPhone: Control Center > Screen Mirroring > ESP32 Agent.
3. `esp32agent screenshot` should now write a PNG of the phone's screen.

Pairing is done by the CLI itself (X25519 key exchange, then AES-GCM sessions; see `docs/cli-protocol.md`),
never by the OS, so stale Bluetooth bonds don't matter. Keys live in the user config dir
(`~/Library/Application Support/esp32agent`, `~/.config/esp32agent`, `%AppData%\esp32agent`), mode 0600.

## Commands

| Command | |
|---|---|
| `devices` | boards nearby (`id`, `paired`, `connected`) |
| `pair`, `unpair` | pair this computer; forget the board here |
| `screenshot [--format png\|jpeg] [--quality N] [--scale F] [--max-size N] [--output PATH\|DIR/\|-]` | the screen after the last action settled; default a file in the current directory |
| `io tap X,Y [--aim]` | coordinates are pixels of a full-size screenshot |
| `io longpress X,Y [--duration MS]` | |
| `io swipe X1,Y1,X2,Y2` | |
| `io text 'TEXT'` | ASCII; Chinese is typed as pinyin |
| `io keys COMBO` | `enter`, `esc`, `tab`, `backspace`, `space`, arrows, `cmd+a`, `shift+tab` ... |
| `io button HOME` | the only button |
| `screencapture --format h264\|mjpeg` | live video to stdout, e.g. `\| ffplay -` |
| `device info` | board status: `ap` (mirroring), `fz` (video frozen), `busy` (the app holds the phone), `usb`, `ble` |
| `calibrate` | measure the pointer (runs by itself on the first tap; needs the pointer visible) |
| `mcp` | MCP server on stdio |
| `skill install` | writes the agent skill to `~/.claude/skills/esp32agent/` |
| `daemon [stop]`, `version` | |

With several boards around pass `--device <id>` (the 12-hex id or the 4 hex digits of its name) or set
`ESP32AGENT_DEVICE`. Output is `{"status":"ok","data":...}` or `{"status":"error","error":"..."}` (exit code 1).
mobilecli commands that need an on-device agent (`apps`, `dump ui`, `fs`, `webview`, ...) answer
`not supported on ESP32 Agent`.

The first command starts a background `esp32agent daemon` that holds the Bluetooth session and decodes the video;
commands reach it over a unix socket in the config dir (log: `daemon.log` there). It exits after 10 minutes idle.

## Agents

```sh
claude mcp add esp32agent -- esp32agent mcp      # Claude Code
codex mcp add esp32agent -- esp32agent mcp       # Codex
esp32agent skill install                         # Claude Code skill (the loop, typing rules)
```

MCP tools: `screenshot` (returns the image), `tap`, `longpress`, `swipe`, `type_text`, `press_key`, `press_button`,
`device_info`. The loop is screenshot, decide, one action, screenshot: see [SKILL.md](SKILL.md).

## Limits

- The iOS app has priority: while it drives the phone (and 20 s after), pointer and keyboard commands fail with
  `busy: the app is using the phone`. Wait and retry.
- Video comes over Bluetooth: screenshots can lag up to about a second and animations are choppy.
- Taps are relative mouse moves, dead-reckoned from the top-left corner and re-homed every 10 gestures; accuracy
  depends on calibration (`calibrate`, `io tap --aim`).
- Typing is ASCII only (one key per character); no clipboard, no volume/power buttons, no app install or launch.

## Development

```sh
cd cli && go vet ./... && go test ./...
make -C hardware/tests/sim      # simulated board (the firmware's cli_link.cpp): enables the integration test
ESP32AGENT_SIM=$PWD/hardware/tests/sim/cli_sim esp32agent screenshot   # the CLI against the simulator
```

Release: push a tag `cli-vX.Y.Z`; `.github/workflows/cli.yml` builds darwin (cgo, CoreBluetooth), linux and
windows (pure Go) for amd64/arm64 and uploads the archives with `checksums.txt`. Installer testing:
`ESP32AGENT_ARCHIVE=/path/esp32agent_darwin_arm64.tar.gz sh cli/install/install.sh` (checksums.txt next to it).
