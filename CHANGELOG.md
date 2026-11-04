# Changelog

## Unreleased (main)

- Siri AI developer preview (off by default, see `docs/siri-ai-app-intents.md`): tool intents to run a
  task, stop the run, check the run and replay a recorded run; an app skill for multi-step guidance in
  `Skills.skillsbundle`; and view annotations that tell Siri which run is on screen.
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
