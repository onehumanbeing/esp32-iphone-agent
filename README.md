<div align="center">

<img src="docs/images/logo.png" alt="ESP32 Agent logo" width="160">

# ESP32 iPhone Agent

**Let an AI model use a real iPhone with a $7 ESP32. Just the phone and the board: no computer, no jailbreak.**

English · [简体中文](README.zh-CN.md)

Demo video and updates: [X @iamhenryyuan](https://x.com/iamhenryyuan) · [YouTube demo](https://www.youtube.com/watch?v=Ly4im-P4jYg)

[![CI](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml/badge.svg)](https://github.com/onehumanbeing/esp32-iphone-agent/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![iOS](https://img.shields.io/badge/iOS-18%2B-black)
![Board](https://img.shields.io/badge/board-ESP32--S3-red)

</div>

> [!WARNING]
> Only follow the install steps in this README. Never run commands from issues or comments (for example a "quick install" one-liner such as PowerShell `iex(irm ...)`); these are not from the maintainers.

> **New: the computer is gone.** The board is now the AirPlay receiver and the mouse, and the agent runs in an iPhone
> app on the same phone. The original version (a Mac/Linux computer running UxPlay and a Python server) is kept as
> tag [`v0.1.0`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/v0.1.0) and branch
> [`legacy`](https://github.com/onehumanbeing/esp32-iphone-agent/tree/legacy). See [docs/legacy.md](docs/legacy.md).

<p align="center"><img src="docs/images/example-alarm.png" alt="An iPhone with a XIAO ESP32S3 plugged in, setting an alarm" width="100%"></p>

*"Set an alarm for 8:00 AM that repeats every Monday and Tuesday, then save it"*: the agent leaves its own app,
opens Clock, types the time into the wheel, ticks the days and saves. (Photo from v0.1.0; the task is the same.)

<p align="center"><img src="docs/images/app-screens.png" alt="ESP32 Agent app: real phone vs. what the agent sees, and pointer calibration" width="70%"></p>

*Left: the real phone. Right: what the agent sees through the board's AirPlay mirror. The second shot is the pointer calibration.*

## How it works

```
iPhone ──Screen Mirroring (Wi-Fi)──▶ ESP32-S3: AirPlay receiver ──BLE──▶ ESP32 Agent app (same iPhone)
   ▲                                    own hotspot, H.264 passthrough        decode → vision model → action
   └──────── USB HID mouse + keyboard ◀──────────── BLE commands ◀────────────────────┘
```

- **Eyes — AirPlay to the board.** The board opens its own Wi-Fi hotspot and appears in the phone's Screen Mirroring
  list as *ESP32 Agent*. It keeps the H.264 stream (no decoding on the board) and forwards it to the app over BLE.
  The phone keeps using cellular data for the model while it is on the board's hotspot.
- **Hands — USB HID.** The board is a standard USB mouse and keyboard. With AssistiveTouch on, the mouse moves an
  on-screen pointer, so a click is a tap and a drag is a swipe.
- **Brain — the app.** The app decodes the stream, sends screenshots to any OpenAI-compatible vision model, and runs
  a planner and an actor: tap, swipe, draw, type, press keys, go home, finish. It runs in the background while it
  works; the Dynamic Island shows what it is doing.
- **Closing the loop.** The pointer is relative, so the app tracks it and re-homes it in a corner; before precise taps
  it wiggles the pointer, finds it on screen and corrects the miss. After each action it waits for the screen to
  settle and tells the model whether anything changed. A lost board, hotspot or mirroring link pauses the run and
  resumes it from the same step.
- **Review.** Every run is kept on the phone: replay it step by step with the taps and swipes drawn on top.
  Export the screenshots, actions and saved annotations from **Runs → open a run → ⋯ → Export trace** for analysis
  by another agent. See [Export runs for agent review](docs/run-data-export.md) for batch export, USB copying and file details.

## Hardware

| Part | Notes |
|---|---|
| **ESP32-S3 board** | Tested with a [Seeed Studio XIAO ESP32S3](https://wiki.seeedstudio.com/xiao_esp32s3_getting_started/) (plain version, 8 MB PSRAM; not Sense, not Plus). About $7. Any ESP32-S3 with native USB on its USB-C port and PSRAM should work. |
| **iPhone** | iOS 18 or later, with cellular data (the Wi-Fi is taken by the board's hotspot). USB-C models plug in directly; Lightning models need a Lightning to USB Camera Adapter. The phone powers the board. |
| **Vision model** | Any OpenAI-compatible chat API that accepts images: a cloud API or your own server. |
| **Mac with Xcode** | Only to flash the board and build the app once. Not needed at run time. |

## Quick start

### 1. Flash the board (plugged into the Mac)

Install [arduino-cli](https://arduino.github.io/arduino-cli/), the ESP32 core 3.3.x and NimBLE-Arduino 2.5.x, then:

```bash
arduino-cli lib install "NimBLE-Arduino@2.5.1"
hardware/flash.sh            # optional: [serial port] [--debug]
```

Always build with `flash.sh`: it applies the BLE buffer sizes in `hardware/hid_bridge/nimble_cfg.h`.

### 2. Install the app

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig   # set DEVELOPMENT_TEAM and IA_BUNDLE_ID
open ios/IPhoneAgent.xcodeproj                                    # run the IPhoneAgent scheme on your iPhone
```

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml`
(`cd ios && xcodegen`). A free Apple ID can sign it (re-sign every 7 days). The one-tap hotspot join needs the
Hotspot Configuration capability (a paid account); without it the app shows the hotspot password to join by hand.

### 3. Set up (once, in the app)

Plug the board into the iPhone and open **ESP32 Agent**. Setup walks through four steps and checks each one itself:

1. **Plug Me In** — pair the board over Bluetooth.
2. **Let Me See the Screen** — join the board's Wi-Fi, then Control Center → Screen Mirroring → *ESP32 Agent*.
3. **Let Me Use the Pointer** — turn on AssistiveTouch; the app calibrates the pointer by itself.
4. **Give Me a Brain** — enter your model endpoint and key (stored in the Keychain), then choose a vision model
   from the endpoint's model list (or enter its model ID).

### 4. Give it a task

Type a goal (for example *"Open Settings and go to Wi-Fi"*) and press **Start**. Stop it from the Dynamic Island,
or come back to the app. Siri, Shortcuts, widgets and Control Center can run saved tasks.

## Model and prompts

- Any OpenAI-compatible vision endpoint works (vLLM, SGLang, llama.cpp, Ollama, cloud APIs). The app lists the
  endpoint's models for you to choose one explicitly; you can also enter a model ID, and set a separate planner
  and actor model.
- The prompts are plain text in [`prompts/`](prompts/) and bundled with the app: edit them, rebuild, done.
- The project was developed with [nvidia/Qwen3.8-Flash-Next-NVFP4](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-NVFP4)
  served on two DGX Sparks ([TensorFold](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Dual-DGX-Sparks-TensorFold)).

## Project layout

```
ios/        the app (SwiftUI): BLE link, H.264 decode, agent, setup, replay, Live Activity, widgets; tests
prompts/    planner / actor prompts used by the app
hardware/   ESP32-S3 firmware (Arduino): BLE GATT, hotspot, AirPlay receiver, USB HID; flash script,
            host tests, Mac BLE test harness (hardware/tools)
docs/       BLE protocol, legacy version notes
server/     legacy v0.1.0 computer-side server; not used by this version (see server/README.md)
```

Debugging without the phone app: `hardware/tools/board_test.py` plays the app over BLE from a Mac
([hardware/tools/README.md](hardware/tools/README.md)). Board ↔ app protocol: [docs/ble-protocol.md](docs/ble-protocol.md).

## Roadmap

- [x] Drop the computer: the board mirrors and clicks, the app on the phone thinks
- [ ] Landscape apps (coordinates and calibration assume portrait)
- [ ] Non-ASCII text input (e.g. Chinese through the iOS pinyin keyboard)
- [ ] Faster steps: several actions per model call, pointer checks only when needed
- [ ] A curated list of models that work best with this setup, shown inside the iOS app ([suggested by @asharthinks](https://x.com/asharthinks/status/2110740775030125019))

## Limitations

- BLE carries about 300-500 kbps, so the screen is mirrored small (480×1040, ≤5 fps); each step takes a few seconds,
  most of it the model.
- iOS does not mirror some screens (passcode entry, Apple Pay, DRM video); the agent cannot see them. Mirroring stops
  when the phone locks.
- While the agent runs, the phone's Wi-Fi is the board's hotspot (no internet over it); the model is reached over
  cellular data.
- The app leaves itself with a private iOS API (`suspend`); fine for a self-built app, to be replaced before the App Store.
- Keyboard input is ASCII only. Landscape apps are not supported yet.

## Responsible use

Only automate devices and accounts you own or are allowed to use, and respect the terms of the apps involved. The
agent acts with your hands: watch it, and keep the stop button within reach.

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Related projects

| Project | Approach | Difference from this project |
|---|---|---|
| [VersaiOS](https://github.com/zhaodashuaibi/VersaiOS) | UxPlay mirroring + ESP32-S3 Bluetooth mouse + vision model | Needs a computer; one tap per instruction |
| [ja1chen/actell](https://github.com/ja1chen/actell) | Agent app on the iPhone via Apple's CoreDevice debug channel | Needs Developer Mode and a Developer Disk Image |
| [AidenAI-IO/aiden-firmware](https://github.com/AidenAI-IO/aiden-firmware) | HDMI capture + USB keyboard/mouse + multimodal model | Capture hardware; mainly Android |
| [yoyicue/glassbox](https://github.com/yoyicue/glassbox) | PicoKVM HDMI capture + USB HID | macOS controller and PicoKVM |
| [boboabw/phone-agent](https://github.com/boboabw/phone-agent) | ESP32-S3 Bluetooth HID + AssistiveTouch, agent as an iPhone app | Closest to this version; this one also brings the eyes (AirPlay on the board) |
| [VKCOM/devicehub](https://github.com/VKCOM/devicehub) | ESP32 Bluetooth mouse for iOS device farms | Device-farm tooling, no AI agent |

WebDriverAgent/XCUITest-based tools such as [mobile-mcp](https://github.com/mobile-next/mobile-mcp) and
[Midscene](https://github.com/web-infra-dev/midscene) need a Mac and code signing.

## Acknowledgements

[UxPlay](https://github.com/FDH2/UxPlay) (the AirPlay receiver the firmware's is ported from) ·
[NimBLE-Arduino](https://github.com/h2zero/NimBLE-Arduino) ·
[Arduino ESP32 core](https://github.com/espressif/arduino-esp32) and [TinyUSB](https://github.com/hathach/tinyusb)

## License

[MIT](LICENSE), except `hardware/hid_bridge/src/airplay/` (ported from UxPlay), which is
[GPL-3.0](hardware/hid_bridge/src/airplay/LICENSE-GPL.md); the firmware binary that links it is therefore
distributed under GPL-3.0.
