---
name: esp32agent
description: See and drive a real iPhone through an ESP32 Agent board (USB mouse/keyboard + AirPlay screen mirroring, reached over Bluetooth). Use when asked to look at, tap, type on, or operate the iPhone, or to test an iOS app on the device.
---

# esp32agent

`esp32agent` talks to an ESP32 Agent board plugged into the iPhone. The board is the phone's USB mouse and
keyboard and receives its AirPlay screen mirroring; this computer reaches it over Bluetooth. Every command prints
JSON: `{"status":"ok","data":...}` or `{"status":"error","error":"..."}`. The MCP server (`esp32agent mcp`)
offers the same as tools: screenshot, tap, longpress, swipe, type_text, press_key, press_button, device_info.

## Setup (once)
- `esp32agent pair` within 3 minutes of plugging the board into the iPhone.
- Screen Mirroring on the iPhone: Control Center > Screen Mirroring > ESP32 Agent.
- `esp32agent calibrate` (also runs by itself on the first tap). It needs the mouse pointer visible on screen.

## The loop
1. `esp32agent screenshot` (writes a PNG in the current directory and prints its `filePath`; read the image).
   It waits until the screen has settled after your last action, so it never shows the screen from before it.
2. Decide one action from what you see.
3. Act, with coordinates in pixels of that screenshot (full size: don't pass `--scale`/`--max-size` if you
   take coordinates from it):
   - `esp32agent io tap X,Y` (add `--aim` after a missed tap: finds the pointer and corrects first)
   - `esp32agent io longpress X,Y --duration 1500`
   - `esp32agent io swipe X1,Y1,X2,Y2` (scroll a list: swipe up from the lower to the upper middle)
   - `esp32agent io text 'hello'`, `esp32agent io keys enter`, `esp32agent io keys cmd+a`
   - `esp32agent io button HOME` (Home Screen)
4. Screenshot again and check the result before the next step. Never chain several taps blind.

## Typing
- The board types printable ASCII only, one key per character.
- Chinese is typed as pinyin: `io text '卫生纸'` types `weishengzhi`. With the iPhone's Chinese (pinyin)
  keyboard active, commit the first candidate with `io keys space`, or screenshot and tap the right candidate.
  Many search boxes accept the plain pinyin as well.
- The board is a hardware keyboard, so iOS may hide the on-screen keyboard; the text field still takes the keys.
- Tap the text field first so it has focus; `io keys cmd+a` then `io keys backspace` clears it.

## Errors to act on
- `busy: the app is using the phone`: the iOS app is driving right now. Wait and retry later; don't fight it.
- `screen mirroring is off`: ask the user to start Screen Mirroring to ESP32 Agent.
- `video frozen`: ask the user to stop and restart Screen Mirroring.
- `not paired`: ask the user to replug the board and run `esp32agent pair` within 3 minutes.
- `phone usb asleep`: the phone is locked; ask the user to unlock it.
- `not supported on ESP32 Agent`: there is no app list, UI tree, file access or webview; work from screenshots.

## Limits
- Video comes over Bluetooth: a screenshot can be up to a second behind, animations look choppy.
- Only HOME as a button; no volume, power, or app install/launch (open apps from the Home Screen or Spotlight:
  `io button HOME`, swipe down in the middle, `io text 'Settings'`, `io keys enter`).
