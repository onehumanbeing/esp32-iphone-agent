# Changelog

Full changelog with board firmware and every channel: [handsy.tech/docs/changelog](https://handsy.tech/docs/changelog).

## Unreleased (main)

- App: a start whose Home gestures did nothing while the board's USB is up, but with no mouse on this iPhone,
  says to plug the board straight into this iPhone and tap Allow for the accessory, and goes on by itself once
  the mouse shows up (30 s); a board whose USB is asleep asks to unlock the iPhone. It used to say "plug it into
  USB-C" to users whose board was plugged in.
- App: when no fresh screen image arrives at startup, the app reopens the board's stream once before asking to
  restart Screen Mirroring.
- Agent: `open` with a Chinese app name types its pinyin letters on the English keyboard first (Spotlight finds
  apps by pinyin), and the name itself through the pinyin keyboard only when the letters list nothing. Typing
  Chinese, a word that is not the first candidate goes in by halves instead of by its number key, and a word that
  did not commit has its letters cleared from the field.
- Agent: a third tap on the same spot while the screen stays much the same is held back once and the model asked
  for another way, even when each tap read as a change (the pointer, an animation).
- App: the firmware check on Home runs at most once a minute, in a task a reloaded Home doesn't cancel. Some
  starts ran hundreds of cancelled checks a second on the main thread.

## App 1.0.6 (TestFlight)

- Calls: Control Center is closed with the Home key alone, and Home flicks up at most once, only when the key did
  nothing: the extra flicks folded the Live Captions panel away mid-call. To hang up, the agent closes Live Speech
  first (its keyboard covers the End button) and checks that the call screen says the call ended.
- Dynamic Island: the step counter stays on one line, a waiting timer replaces the progress bar and the buttons are
  small, so nothing is cut off.
- App · CLI: one memory on the phone and the computer. Settings › Memory › ⋯ exports `MEMORY.md` and imports another
  copy (an entry with the same id or words keeps the newer one; passwords, codes and long numbers never come in).
  The CLI keeps the same file: `esp32agent memory list | add | rm | search | export | import`, and the MCP tools
  `memory_recall` and `memory_add`.
- Firmware (optional build) · App: an absolute mouse, `hardware/flash.sh --abs` (#99, by @chenshaorong0118). With
  AssistiveTouch on, a tap lands at its screen fraction (`abs X Y`): no homing, calibration or aiming. The status
  says `abs: 1` and the app sends coordinates; a board flashed back answers `err unknown` and the app goes back to
  the relative mouse. Home, back and the switch to the previous app are fast strokes; drags glide at the relative
  mouse's speed. The default firmware is unchanged.
- Agent: a task over many items may run up to 1000 steps (others stay at 300); Home shows the step and how many
  items are listed instead of "up to 300". Every 10 steps the run saves its listed items, so Continue picks them up.
- Agent: in a task over many items, taps that followed the same tap the same way twice (say "…", then Delete,
  then OK) are done by the app from the third time on, each found by its words on the screen and checked to change
  it; anything missing, or prices and paying on the screen, hands back to the AI. Fewer model calls per item.
- Agent: a task over many items or that deletes (delete, clear, unfollow, all, every, or a repeat-until intent)
  lists the matching items first and asks once with how many and which, even when Ask first is Payments only; the
  first delete-like tap before that is held once and the AI is told to list first. The question shows up to five
  of the items collected.
- App: Standby in Dynamic Island (Settings, off by default): between runs the island shows your three most used
  intents and New Task. An intent tapped there runs on the app you are in; New Task (also a Control Center control)
  opens a quick sheet to type a task or pick an intent, and the run goes back to the app you came from first. While
  a run goes, the island's bubble button opens the same sheet to add to the task. A task started while another app
  is in front works on that screen instead of going to the Home Screen first.
- Agent: words added while a run goes (the field under the running task on Home, the quick task sheet, or Siri
  and Shortcuts while a run is on) join its next step: the review shows them, every later step sees them, and that
  step goes to the planner so the plan follows.
- Record: a demonstration is saved as what was meant. Opening an app from the Home Screen, a folder or Search
  becomes one `open` step; a tap is named by the text at its spot on the screen; taps on the on-screen keyboard
  are left out (the type step holds the text) and its return key becomes Return; a detour that ends back on the
  same screen is marked left out (mark it correct to keep it).
- Record: text typed from the instruction's words follows the instruction: after the words change, the AI types
  what the instruction says now.
- Record: "Working out the steps" shows which part it is on and the time so far. The review opens at step 1, with
  Next Unsure to jump to the yellow steps. Review screens are blurred until tapped (Settings › Blur screens in
  reviews).
- Intents: editing an intent's instruction checks its steps, name and checklist against the new words and proposes
  the changes; nothing changes until you tap Apply.
- Intents: a run that fails adds one hint from its notes to the checklist (words only, phone numbers masked);
  checklist rows can be swiped away.
- App: a recorded step that misses is described to the AI in words (its label, or the text near the tapped spot on
  the recorded screen), never by its coordinates, and the AI may skip a step the screen or task no longer needs.
  Fixed taps landed on the keyboard, a wrong chat or a photo, and the step's raw JSON showed in the status.
- App: in an intent with AI steps, a recorded tap that nothing names is skipped when the screen differs, instead of
  being tapped at its old spot.
- App: a run of an intent that fails or is stopped demotes the recorded steps that missed: a tap nothing names is
  removed, other steps become AI steps. Undo on the intent page puts the old steps back.
- App: opening a run's review while it is already showing keeps it open instead of closing and presenting it again
  (one possible cause of the review closing by itself right after a stopped run).
- App: Home's intent list masks phone numbers in the instruction preview.
- App: the free-line run end sends the board firmware as `0.2.5`, not `v0.2.5`.
- App: usage stats for a run that could not start say at which startup step it stopped and a fixed error kind
  (never the error text or the task); the free-line run end sends the same step.
- Agent: a tap on the Dynamic Island (where the run's Live Activity shows) is never sent: one just above a field
  under the island moves a few units down into the field, one higher up goes back to the AI with where to tap
  instead. Fixed a search field right under the island opening the agent app and leaving the task's app.
- Agent: a tap on the Home Screen's Search pill that reads as no change is not pressed again by itself: Spotlight
  over a plain wallpaper can look unchanged, and the second press landed on Spotlight's suggestions and opened
  another app. Each tap logs where the pointer went from and to.
- Agent: `home` flicks up from the home bar when the Home key left the same app on screen and only something that
  moves by itself changed (an animated sheet), not only when nothing changed. An `open` whose Return did nothing
  tells the AI to tap the app in Spotlight's results.
- Prompt: a goal to look at, find or browse something ends with done once the screen shows a match, with a short
  answer, instead of browsing on; never tap the Dynamic Island.

## App 1.0.5 · firmware v0.2.5 (TestFlight)

- App: **Tools (Beta)**: the agent can look things up on the web when a task needs it (search tool use), with
  tools exported and imported as JSON.
- App: **Phone calls and text messages (Beta, experimental)**: Call and Text templates. A call dials, speaks through
  iOS Live Speech and hears the other side through Live Captions, as a script: code opens Phone and the Control
  Center buttons, the model dials, talks and hangs up. A setup guide (with a clip) shows before each call until
  Don't Show Again; it needs Live Captions › Keep Call Captions › 1 Hour, or iOS keeps call captions out of Screen
  Mirroring. An intent has a Phone call switch that follows its words ("Call …") until set by hand. Calls are not
  stable yet: see #150.
- App: **intents improve themselves**: when an intent's saved steps miss and the AI finishes the task, that run's
  steps replace them; a typed-in intent's first run that works becomes its reference; lessons from done runs go on
  its checklist (up to 8). Wrong in the Dynamic Island (90 s) or Undo on the intent takes it back; Settings › Intents
  learn from runs turns it off.
- App: a recording is a run: every change is named and kept as a trace, reviewed, continued and saved as an intent.
- App: open APP is done by code and read back: Spotlight (or the Home Screen's Search button when cmd+space does
  nothing), only the name asked for; the model picks another name in the iPhone's language.
- App: Chinese, accented and other scripts typed or pasted reliably; a full-width "？" read by OCR is not a wrong symbol.
- App: taps outside the screen are not sent; a confirmed or self-moving target is never pressed twice; Home flick
  in one board command; Pause drops a gesture already chosen.
- App: Handsy key: runs on a plan's key instead of the free runs.
- App: the name is a build setting (`IA_APP_NAME`, shown on the Home Screen and in texts about the app). TestFlight
  and source builds stay ESP32 Agent. The board keeps its names in Screen Mirroring and Bluetooth (ESP32 Agent),
  so setup texts that point at them are unchanged. Permission prompts and Shortcuts descriptions no longer carry
  the app's name.
- App: Settings › Privacy shows the installation ID Handsy Free keeps records under, with a mail link that asks
  to delete them (the privacy policy pointed at an ID the app did not show).
- Firmware: the board's name in Screen Mirroring and Bluetooth is a build option (`flash.sh --name NAME`, default
  ESP32 Agent); the hotspot name is unchanged. The app's setup texts name the board it last saw.
- App: what is sent and to whom reads the same everywhere. The send sheet names who runs Handsy Free (Holomix, Inc.)
  next to its address and says that simple steps may go to its provider TypeSafe; Your Data no longer says run data
  is never uploaded without saying what a run sends. Demo data asks for the same consent before its first run when
  a model is set up, and the first setup page offers the demo to try the app without a board (No board yet? Try the
  demo). The privacy manifest lists the installation ID and run content of Handsy Free.
- App: one agreement at first launch. Your Data now also states the risks, and Agree and Continue accepts them and
  allows sending to Handsy Free when nothing else is set up yet, so the model page does not ask again. The welcome
  page has no switch: Get Started, or Accept and Get Started after Not Now. Another service or Jev still asks.
- App: Pause finishes the gesture already in flight, then does not send one the model had chosen. The next
  look decides from the screen in front. Frames from while the run is paused are left out of its video.
- Siri AI developer preview (off by default, see `docs/siri-ai-app-intents.md`): tool intents to run a
  task, stop the run, check the run and replay a recorded run; an app skill for multi-step guidance in
  `Skills.skillsbundle`; and view annotations that tell Siri which run is on screen.

## Firmware v0.2.5 (TestFlight)

- Board: a mirrored video packet it has to drop for good is logged (header and first bytes) and counted as
  `lost` in the status, so the app can tell a broken picture from a still screen and ask for mirroring to
  restart at once.
- Board: `press_for MS`, a held press that comes up by itself (long press, or a press then moves to drag).
- Board: `flick DX DY SPEED`, press, move and release in one command, so the Home Screen flick never lingers into the app switcher.
- Board: `result ID` answers the last 8 replies again, for a reply that never arrived.
- Board: the CLI's `net` goes through while the app drives the board, so the board can always be put back on a
  network.

## App 1.0.4 (TestFlight)

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

## CLI 0.1.4 (npm `esp32agent` 0.1.5, dsh plugin 0.1.3)

- Daemon: fixed a deadlock where the CLI daemon could hang while the app was connected (a status update notified
  the app while still holding the connection lock, #122).

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
