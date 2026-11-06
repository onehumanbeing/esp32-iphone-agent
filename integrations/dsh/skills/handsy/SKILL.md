---
name: handsy
description: See and drive a real iPhone through an ESP32 Agent (Handsy) board with the esp32agent CLI or MCP server. Use when asked to look at, tap, swipe, type on, or operate an iPhone, or to test an iOS app on a real device.
license: MIT-0
metadata:
  openclaw:
    requires:
      bins: [npx, ffmpeg]
    envOptional: [ESP32AGENT_DEVICE]
    homepage: https://handsy.tech
---

# Handsy: drive a real iPhone with esp32agent

An ESP32 Agent board (Handsy) plugs into the iPhone (USB-C models directly, Lightning models through a Lightning to
USB Camera Adapter) and acts as the phone's USB mouse and keyboard. It also receives the iPhone's AirPlay screen mirroring. Your computer reaches
the board over Bluetooth with the `esp32agent` command line tool, which is also an MCP server. No jailbreak is
needed.

iPhone only for now. iPad support is coming soon.

## Prerequisites

- A Seeed Studio XIAO ESP32S3 board (8 MB flash, 8 MB PSRAM), or a similar ESP32-S3 board with native USB.
- Board firmware v0.2.2 or later. Install it in Chrome or Edge at https://handsy.tech/install
  (one USB data cable, nothing else to install).
- On the iPhone:
  - AssistiveTouch on (Settings > Accessibility > Touch > AssistiveTouch), so the mouse pointer shows and taps.
  - Screen Mirroring to the board: join the board's Wi-Fi, then Control Center > Screen Mirroring > ESP32 Agent.
  - The phone unlocked while the agent works.
- On the computer: Bluetooth, Node.js 18 or later (for `npx`), and `ffmpeg` (needed for screenshots).

## Install

Nothing to install up front; `npx` fetches the CLI:

```sh
npx -y esp32agent version
```

Or install it globally with `npm install -g esp32agent` and call `esp32agent` directly. The examples below use
`npx -y esp32agent`; with a global install, drop the `npx -y`.

MCP server (stdio), if your agent does not already have it from this plugin:

```sh
claude mcp add esp32agent -- npx -y esp32agent mcp
```

Other MCP clients:

```json
{ "mcpServers": { "esp32agent": { "command": "npx", "args": ["-y", "esp32agent", "mcp"] } } }
```

## Pair (once per computer)

1. Plug the board into the iPhone. Within 3 minutes run `npx -y esp32agent pair`.
2. Start Screen Mirroring on the iPhone to ESP32 Agent.
3. `npx -y esp32agent screenshot` should now save a PNG of the phone's screen.
4. `npx -y esp32agent calibrate` measures the pointer. It also runs by itself before the earliest tap. It needs
   the pointer visible on screen.

## MCP tools

| Tool | What it does |
|---|---|
| `screenshot` | The screen now, after the last action settled. Other tools take pixel coordinates of this image |
| `tap` | Tap at `x`, `y`; `count: 2` double-taps |
| `longpress` | Press and hold at `x`, `y` (`duration_ms`, default 1000) |
| `swipe` | Swipe from `x1`, `y1` to `x2`, `y2` |
| `type_text` | Type into the focused field (ASCII; Chinese is typed as pinyin) |
| `press_key` | `enter`, `esc`, `tab`, `backspace`, `space`, arrows, `cmd+a`, `shift+tab` ... |
| `press_button` | `HOME` only (go to the Home Screen) |
| `device_info` | Board status: mirroring (`ap`), video frozen (`fz`), app busy (`busy`), `usb`, `ble` |
| `history` | `action: list` (recent runs) or `show` (one run's steps with their screenshots) |
| `intent_list`, `intent_show`, `intent_save` | Saved tasks: list, show one, save what worked |

Every tool takes an optional `device` (board id) when more than one board is nearby.

## CLI commands

Every command prints JSON: `{"status":"ok","data":...}` or `{"status":"error","error":"..."}` (exit code 1).

| Command | What it does |
|---|---|
| `devices` | Boards nearby (`id`, `paired`, `connected`) |
| `pair`, `unpair` | Pair this computer with the board; forget it here |
| `screenshot [--format png\|jpeg] [--quality N] [--scale F] [--max-size N] [--output PATH\|DIR/\|-]` | Save the screen; prints `filePath` |
| `io tap X,Y [--aim] [--count N]` | Tap; `--aim` finds the pointer and corrects before tapping |
| `io longpress X,Y [--duration MS]` | Press and hold |
| `io swipe X1,Y1,X2,Y2` | Swipe |
| `io text 'TEXT'` | Type ASCII text |
| `io keys COMBO` | Press a key or combo |
| `io button HOME` | Home Screen |
| `device info` | Board status |
| `calibrate` | Measure the pointer |
| `history list`, `history show RUN\|latest`, `history new` | What was done on the phone; start a new run |
| `intent list`, `intent show NAME`, `intent save ...`, `intent delete NAME` | Saved tasks |
| `intent export NAME [--screenshots] [--output FILE]`, `intent import FILE` | Move saved tasks to and from the iOS app |
| `upgrade [--check]`, `version` | Update the CLI; print its version |
| `mcp` | Run the MCP server on stdio |

With several boards nearby pass `--device <id>` or set `ESP32AGENT_DEVICE`.

## The see-act loop

1. Take a screenshot (`screenshot` tool, or `esp32agent screenshot` and read the PNG at `filePath`).
   It waits until the screen has settled after your last action.
2. Decide one action from what you see.
3. Do that one action, with coordinates in pixels of that full-size screenshot. If you used `--scale` or
   `--max-size`, convert the coordinates back to full size.
4. Take another screenshot and check the result before the next step. Never chain several taps blind.

Tips:
- To scroll a list, swipe up from the lower middle to the upper middle of the screen.
- To open an app: press HOME, swipe down in the middle of the Home Screen, type the app name, press `enter`.
- If a tap missed, retry with `io tap X,Y --aim`.
- Tap a text field so it has focus before typing. `cmd+a` then `backspace` clears it.
- The board is a hardware keyboard, so iOS may hide the on-screen keyboard; the field still takes the keys.
- Chinese text is typed as pinyin (`io text '拿铁'` types `natie`). With the Chinese pinyin keyboard active, press
  `space` to accept the top candidate, or screenshot and tap the right one.

## Save what worked

After a task succeeds, save it so the next run is faster:
1. `history show latest` (MCP `history`, action `show`) lists the run's numbered steps in 0-1000 screen units.
2. Pick the steps that did the job, skipping misses and retries.
3. `intent save --name 'Alarm 7:00' --prompt 'Set an alarm for 7:00 AM every day' --hint 'Type the time' --from-run RUN --steps 2,3,5`
   (MCP `intent_save`). Keep the prompt short and use at most 6 hints.

To reuse one, `intent show NAME`, convert its 0-1000 coordinates to pixels (x * width / 1000,
y * height / 1000), and check each screen against the step's reference screen. If the screen looks different,
drop the recorded steps and continue with the normal loop.

## Safety

You are using a real phone with the owner's accounts, money and contacts.
- Ask the user to confirm before anything that spends money, sends a message, email or post, calls someone,
  deletes data, changes passwords or security settings, or accepts terms.
- Do not read or copy private content (messages, photos, codes, passwords) beyond what the task needs.
- If a screen asks for a password, passcode, Face ID or a one-time code, stop and hand it to the user.
- Stop and ask when the screen is not what you expected.

## Troubleshooting

| Error or symptom | What to do |
|---|---|
| `not paired` | Replug the board into the iPhone and run `pair` within 3 minutes |
| `screen mirroring is off` | Ask the user to start Screen Mirroring to ESP32 Agent |
| `video frozen` | Ask the user to stop and restart Screen Mirroring |
| `phone usb asleep` | The phone is locked; ask the user to unlock it |
| `busy: the app is using the phone` | The ESP32 Agent iOS app is driving the phone. Wait and retry later |
| `no cli service (firmware too old?)` | Update the board firmware to v0.2.2 or later at https://handsy.tech/install |
| `not supported on ESP32 Agent` | There is no app list, UI tree or file access; work from screenshots |
| Taps land off target | Make sure AssistiveTouch is on and the pointer is visible, run `calibrate`, or use `io tap --aim` |
| Screenshot fails | Check that `ffmpeg` is installed and Screen Mirroring is on |

Limits: screenshots can be up to about a second behind and animations look choppy. Typing is ASCII only, one key
per character. HOME is the only button: no volume or power buttons, and no installing or launching apps directly.

Help: support@handsy.tech · https://handsy.tech
