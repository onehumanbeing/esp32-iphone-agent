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
npm: `npm install -g esp32agent`. The scripts read the release list at `https://handsy.tech/cli/versions.json`
(falling back to GitHub Releases) and check the archive's SHA-256. Screenshots need `ffmpeg` (the installers offer
brew / apt / dnf / winget). Later: `esp32agent upgrade`.

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
| `io tap X,Y [--aim] [--count N]` | coordinates are pixels of a full-size screenshot; `--count 2` double-taps |
| `io longpress X,Y [--duration MS]` | |
| `io swipe X1,Y1,X2,Y2` | |
| `io text 'TEXT'` | ASCII; Chinese is typed as pinyin |
| `io keys COMBO` | `enter`, `esc`, `tab`, `backspace`, `space`, arrows, `cmd+a`, `shift+tab` ... |
| `io button HOME` | the only button |
| `screencapture --format h264\|mjpeg` | live video to stdout, e.g. `\| ffplay -` |
| `device info` | board status: `ap` (mirroring), `fz` (video frozen), `busy` (the app holds the phone), `usb`, `ble` |
| `calibrate` | measure the pointer (runs by itself on the first tap; needs the pointer visible) |
| `net` | the CLI's link (`via`: `ble` or `wifi`) and the board's Wi-Fi. With this computer on the board's network (same Wi-Fi, or its hotspot) commands and video go over Wi-Fi; BLE stays as the way back |
| `net join` | asks for your Wi-Fi's name and password (not echoed), sends them to the board over the Bluetooth session, and waits until the link moves to Wi-Fi. `net join SSID [PASSWORD]` does it without asking. The iPhone mirrors over that Wi-Fi too |
| `net hotspot` | the board opens its own hotspot again |
| `net via auto\|ble` | `ble` keeps the session on BLE (also `ESP32AGENT_TRANSPORT=ble`) |
| `history list`, `history show RUN\|latest`, `history new` | what was done on the phone: runs (newest first, 30), one run's steps; start a new run |
| `intent list`, `intent show NAME\|ID` | saved intents |
| `intent save --name N --prompt P [--hint H ...] [--from-run RUN [--steps 1,3,4]]` | save an intent; steps are the run's replayable moves (all, or the numbers from `history show`) |
| `intent delete NAME\|ID` | |
| `intent export NAME\|ID... [--screenshots] [--output FILE]` | `.esp32intent` file the iOS app imports; reference screens only with `--screenshots` |
| `intent import FILE` | an `.esp32intent` file (from the app or `export`); ones already saved under the same name and prompt are skipped |
| `report --intent NAME [--screenshots]` | prepare a mail with one intent for the developer (see below); interactive |
| `upgrade [--check] [--force]` | install the latest release (`--check`: `current`, `latest`, `update_available`) |
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
`device_info`, and `history`, `intent_list`, `intent_show`, `intent_save`. The loop is screenshot, decide, one action,
screenshot: see [SKILL.md](SKILL.md).

## History and intents

The daemon records every action and screenshot as the iOS app records its runs: `runs/<yyyyMMdd-HHmmss>/steps.jsonl`
in the config dir (actions in 0-1000 screen units, screens as 480-wide JPEGs). A new run starts after 10 minutes
idle or with `history new`; the newest 100 are kept. Nothing leaves the computer.

An intent is a saved task: name, prompt, up to 6 hints and recorded steps with their screens (`intents.json` and
`intent-frames/<id>/` in the config dir, the app's fields). `intent save --from-run RUN` takes the run's replayable
moves (tap, swipe, type, key, home). `intent export` and `intent import` use the app's `.esp32intent` format, so
intents move between the CLI and the iPhone app (AirDrop or Files).

## Share an intent with the developer (optional)

`esp32agent report --intent NAME [--screenshots]` helps improve intents for everyone. It only runs in a terminal
you type in (agents can't call it, and there is no MCP tool for it). It writes a redacted `.esp32intent` to a temp
folder: typed text becomes `•••`, IP addresses are removed, and with `--screenshots` each screen gets the top 7%
(status bar, notifications) blacked out and is shrunk to 480 px wide; other text on the screens stays readable.
It prints exactly what the file holds (name, prompt, hints, step count, screenshots, path) and continues only when
you type `y`: then it opens a mail to `intents@handsy.tech` in your mail app and shows the file. Attach it and send
it yourself; esp32agent never sends anything.

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
windows (pure Go) for amd64/arm64 and uploads the archives with `checksums.txt`. It also leaves a `versions.json`
artifact ([format](install/versions.example.json)); merging it into `https://handsy.tech/cli/versions.json` is
manual. `ESP32AGENT_VERSIONS_URL` points `upgrade` and the installers at another list (tests). Installer testing:
`ESP32AGENT_ARCHIVE=/path/esp32agent_darwin_arm64.tar.gz sh cli/install/install.sh` (checksums.txt next to it).
