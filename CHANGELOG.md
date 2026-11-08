# Changelog

Full changelog with board firmware and every channel: [handsy.tech/docs/changelog](https://handsy.tech/docs/changelog).

## Unreleased (main)

- Siri AI developer preview (off by default, see `docs/siri-ai-app-intents.md`): tool intents to run a
  task, stop the run, check the run and replay a recorded run; an app skill for multi-step guidance in
  `Skills.skillsbundle`; and view annotations that tell Siri which run is on screen.
- App: requests to DeepSeek's API (`api.deepseek.com`) turn thinking off unless Extra body JSON sets `thinking`,
  so a step no longer waits on high-effort reasoning (#118).
- App: the board needs the latest released firmware, not just the oldest one the app works with. On connect an
  outdated board gets the Board Update Required sheet (once no task or recording runs); Skip for Now asks first and
  lasts for that connection only, with a warning on Home until the board is updated. Offline, or a board that needs
  USB first, works as before. Demo data: `-mockFirmware 0.2.0` launches with an outdated board.
- App: opening the model list in Settings › Model no longer crashes on iOS 27.3 (TestFlight 1.0.3): its search
  bar now sits in the navigation bar instead of the bottom of the sheet.
- App: a calibration whose check tap misses by more than 6% (e.g. ±49.8% on a fast pointer, #96) is no longer
  kept: the previous calibration (or none) stays, and the board says it failed and suggests the AssistiveTouch
  pointer settings before trying again. A cancelled or failed run also leaves the previous calibration.

## App 1.0.3 (TestFlight)

- Free line: requests carry the iPhone's model (e.g. `iPhone18,2`, `X-Device-Model`) to adapt to its screen;
  listed in the send consent sheet and the privacy policy. Nothing else is added.
- App: typing Chinese no longer crashes (a Vision text request could resume its continuation twice, #111); the
  app builds with Xcode 26.3 / 27 (ambiguous `cos` / `.pi`, #112).
- App: after a round of several gestures the next step goes to the model, not Jev, so a plan whose first items were
  just done is not redone (Duolingo: a tapped word was taken back out of the answer). Pointer searches log where
  their time goes; the step timing line counts past 40.
- Harness: following the log survives a line cut mid-character. CI: the settle test no longer fails on slow runners.
- App: models that refuse a `temperature` setting get none (#45).

## App 1.0.2 · firmware v0.2.4 (TestFlight)

- Hear the phone (off by default, Settings › Listen to phone audio): the board forwards AirPlay audio, the app
  transcribes it on the iPhone (English plus a second language) and the agent sees what it heard. The second
  language can follow the screen (Automatic). The CLI can listen too (`listen`). Needs firmware v0.2.4.
- Long tasks: no 40-round limit (300-round safety cap; 12 unchanged rounds pause and ask), and any stopped or
  failed run can Continue from here, also after a relaunch.
- More accurate pointer: every move report at one speed (firmware `pace`), speed calibration for short moves,
  the corner offset is calibrated, far pointer readings are checked twice, and the corner move never opens
  Control Center. A later tap in one round checks its target did not move first.
- Steadier video: network checks and pixel work off the main thread (stream drops 41 → 0 in a Duolingo
  lesson), a gap resumes from the last decoded frame, a Wi-Fi/BLE switch no longer resends the whole GOP, and
  the model never sees a frame older than its last action.
- Settings › Developer: Demo data and an audio test.
- Fixed: calibration and the debug log could crash the app (#97); a lost BLE ack could repeat an input (#90).

## CLI 0.1.3 (npm `esp32agent` 0.1.4, dsh plugin 0.1.2)

- `listen`: what the iPhone played in the last 30 s as words. `mode phone` (default) reads what the ESP32 Agent
  app transcribed (App 1.0.2, firmware v0.2.4, Share with the computer on); `mode local` transcribes the raw
  audio here with whisper.cpp. MCP tool `phone_audio`.

## Firmware v0.2.3 · CLI 0.1.2 (2026-11-05)

- Board firmware v0.2.3 (TestFlight channel): CLI link over Wi-Fi (TCP 7202) next to BLE, `net` command for
  the CLI, BLE write-without-response characteristic `cli_in_nr`.
- CLI v0.1.2 (npm `esp32agent` 0.1.3, dsh plugin 0.1.1) — CLI over Wi-Fi: with the computer on the board's network (same Wi-Fi, or its hotspot) the CLI's session moves
  to TCP port 7202 (same sealed frames), and falls back to BLE when it drops. `esp32agent net` shows the link,
  `net join` / `net hotspot` set the board's Wi-Fi, `net via ble` stays on BLE. Over BLE, short frames go as
  write commands (`cli_in_nr`), so commands no longer wait behind video; calibration waits up to 3 s for a frame, moves
  the pointer one axis at a time (old calibrations are redone) and ignores moving clock hands.
- DeepSeek Harness plugin (`integrations/dsh`, npm `dsh-esp32agent`): the esp32agent MCP server plus the
  handsy skill as a dsh bundle. Uses esp32agent 0.1.2 (CLI binary v0.1.1: empty `required` arrays, #77).

## App 1.0 · 1.0.1 (App Store review 2026-10-19, TestFlight 2026-11-02)

- No computer: the ESP32 is the AirPlay receiver (ported from UxPlay) with its own hotspot, and talks to a new
  iPhone app over BLE. The app is the agent: planner/actor loop, pointer calibration, run replay, Live Activity,
  widgets, Siri and Shortcuts, self-healing when the board, hotspot or mirroring drops.
- Prompts moved to `prompts/`.
- Product name: ESP32 Agent.
- `server/` is legacy and no longer needed.
- Notebook and memory: `read` copies items off the screen into a run's notebook (scrolled overlaps merged),
  `write` puts it on the clipboard for `key cmd+v`; long-term memory in `Documents/memory/MEMORY.md`
  (pi-memory layout), only the user's own words and lessons from finished runs, never secrets.
- Chat between runs: earlier turns reach the next task; "continue" picks up where a run stopped.
- Intents as scripts: `ai`, `read`, `write`, `manual` steps, a missed step is repaired by the AI alone,
  `until` + `maxLoops` repeat the steps. Recordings propose `ai` / `read` steps instead of dropping unsure ones.
- Pause / Continue on the Dynamic Island; Ask me first: payments only (default), also sending/deleting, or never;
  steps, time, AI calls and tokens per run.
- Fixed (intermittent): the home-bar flick could start above the home bar when the pointer calibration was off
  near the bottom edge, so iOS ignored it and the run stopped with "The board isn't controlling this iPhone"
  (iPhone 17 Pro Max, iOS 26.3). The flick now pushes the pointer past the bottom edge first.
- A model's `key delete` is sent as `backspace`.
- Fixed: a Wi-Fi video reconnect after the board's GOP buffer filled (a still screen, ~30 min) froze the
  screen until Screen Mirroring was restarted. The app now reconnects with `hello <token> at <ms>` and the board
  goes on right after that unit, also past a full GOP (firmware + app; docs/ble-protocol.md).
- Fixed: after a still screen, the GOP the board resends on reconnect (over a thousand frames) was turned into
  one JPEG per frame; iOS killed the app for CPU. Decoded frames are thinned to one per 0.15 s, newest last.

## v0.1.0

- Computer-side version: UxPlay + Python server + web UI; the ESP32 is a USB HID bridge over Wi-Fi.
