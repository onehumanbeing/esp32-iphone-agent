# Changelog

Full changelog with board firmware and every channel: [manina.ai/docs/changelog](https://manina.ai/docs/changelog).

## Unreleased (main)

- `switch`: back to the app used just before this one (a flick along the home bar), and `swipe X1 Y1 X2 Y2 hold`:
  press and hold, then move (drag an icon, a list row or a text handle). Both checked on an iPhone 13 Pro.
- Opening an app from Settings works: Settings ignores the board's cmd+h and cmd+space, so the open now flicks up
  from the home bar when the Home key leaves the same app in front.
- An app that comes up late after Return is no longer tapped into: one more look before a second Return or a tap
  on the result row (Settings opened, and the tap opened Apple Account). Spotlight's Top Hit header gone counts
  as left Spotlight.
- Harness: `tapcv.py` corrects the pointer with the scale its last move showed, waits for the Screen Mirroring
  list, and closes Control Center until the status bar's clock is back.

## App 1.0.11.1 (TestFlight, a new build of 1.0.11)

**Built and tested with an automated harness: the changes below were found, fixed and checked on a real iPhone by the harness itself.**

- Long press: the agent can press and hold (`tap X Y hold`), for a chat message's menu (Forward, Copy), an icon's quick actions or selecting a word.
- Opening apps no longer hangs on iOS's "Open in …?" prompt, and an English iPhone searches a known app by its English name (Maps, rednote) instead of pinyin.
- Faster Chinese typing: the pinyin for a text is worked out once, with no stall on the first character.
- Faster pointer search: each screen is decoded once.
- Harness (`harness/`): files to and from the app over pymobiledevice3 (about 1.5 s instead of 40 s), `tapcv.py` taps and restarts Screen Mirroring with no one at the phone, `collect.py` walks an app's screens and records screen, text and action, `timing.py` shows where a run's time went.

## App 1.0.11 (TestFlight)

- App: Settings › Model › Sign in with ChatGPT: runs use your own ChatGPT Plus or Pro plan (the same usage limits Codex uses), with no API key.
- App: the Settings note on Look ahead says it is on by default (it has been since 2026-11-25).
- App: the "Let Me Use the Pointer" setup page lists the AssistiveTouch steps one by one, ticks each as it is done, says what it is waiting for (AssistiveTouch, the board's mouse, Screen Mirroring) and, after 20 s on one of them, the likely cause and fix. It looked frozen before.
- App: a landscape app learns its own pointer landings (a separate table from portrait), so a steady miss there is corrected after a few taps.
- App: a landscape app (a game) goes to the model at 540 px on its short side (about 1170x540), as many pixels as portrait; it went at 540x250 and small targets were unreadable.
- App: faster on screens that never stand still: one such step caps every later wait at 0.8 s, a screen seen moving in the last 2 minutes waits at most 1 s, the longest wait for a still screen is 3 s (was 4), and the pointer check waits 0.2 s instead of 0.6 s there.
- App: `tap X Y twice` taps one spot twice, the second click where the first landed; a second tap at the same spot in one reply is no longer aimed again (a game's choose-then-confirm, "tap twice" buttons).
- App: iPhone apps in landscape (games): taps land where aimed. The pointer's calibration was used in portrait sides, so a tap at the right of a landscape screen landed at about a third of its width.
- App: `open` on the pinyin keyboard: a name that is only in the candidate bar goes in with space instead of a tap, and a Return that only put composing letters in is followed by one more Return on the Top Hit.
- App: a `fail` with no reason or a `done` with no answer shows the model's own words (they read as empty).
- App: Chinese typing deletes words the keyboard's first candidate added past the text (你好明天 came out as 你好明天早上), instead of reporting it typed.
- App: `open` presses Return when the app is Spotlight's Top Hit and its name went in as plain letters, instead of finding the pointer to tap the row (about 5 s less per open). Letters still composing on the pinyin keyboard fall back to the tap.
- App: a second task in a row saves its notes and files in its own folder; before, it reused the folder of the task before it.
- App: Chinese is typed as the pinyin of each word (音乐 is yinyue, so Spotlight finds 汽水音乐). The check for another input method no longer counts the on-screen keyboard's keys or Spotlight's suggestions as typed letters, and one failed typing no longer stops Chinese for the rest of the run.
- App: the first launch asks once on the Welcome page whether you have an ESP32 board. Not yet opens manina.ai's page on where to get one (manina.ai/where-to-buy-esp32), then setup goes on. Users who already finished setup are never asked. With usage stats on, only the answer (yes/no) is counted.
- App: a task that names an app no longer opens a system app whose plain name (音乐, 地图, 天气, Music, Maps…) is part of that app's longer name.
- App: a tap that lands far from its target calibrates the pointer at once, even when the screen changed; failed calibrations try again after 3, 6, 12… taps and never stop for the run. Taps undone by back twice in a row find the pointer first.
- App: "no change" counts only when a new screen image came after the action. The same action with no change twice gives the model a hint; three times, one longer look, then the run asks you.
- App: a keyboard that is not system Pinyin (Zhuyin, Wubi, 9-key, a third-party keyboard) is switched once with ctrl+space and the text typed again; if Pinyin can't be reached the typing stops, nothing is sent, and you are told how to add it. Clearing what came out deletes only that, never the field's own text.
- App: Settings › Look ahead is on by default: the next model request starts while the screen settles (cancelled if the screen moves). A request refused because the run's previous one is still open is asked again every 0.4 s instead of after 3 s.
- App: the task's app guide loads while the app opens, not after it.
- App: a board that joined this iPhone's own Personal Hotspot (`net join`) is reached over the hotspot; the app no longer tries to join that Wi-Fi after the board restarts, and shows no "turn off Personal Hotspot" warning for it.
- App: when Screen Mirroring is connected but the board gets no picture at all (gop 0, 0 fps) for 30 s, the start stops and says to restart Screen Mirroring, or to use another Wi-Fi when the board is on this iPhone's own Personal Hotspot (iOS sends no picture there). It used to wait up to 5 minutes.
- App: the Manina AI key field, plan card, key links and the key-only search tool are in the App Store build only; TestFlight and builds from this repository show none of them and ignore a saved key. There the field saves only a whole key (hsk_live_… with its 43 characters). The free-line note no longer says "up to 3 minutes per run" (runs last up to 30 minutes and go on while they work).
- App: on iOS 27 a pull down to refresh that started on an intent's play button ran that intent when the finger lifted; a play tap during a pull, or within 0.8 s after it, is ignored.
- App: a plain `wait` watches the screen and goes on as soon as something changes (a spinner or a video moving by itself doesn't count), up to 15 s, instead of asking the model again after one settle; `wait 10` waits that long. A loading page no longer costs a model step per look.
- App: when the iPhone itself is slow (the app keeps waiting seconds for the CPU, as for a few hours after an iOS update), Home shows a tip saying so, and names the update when iOS changed in the last two days. Slowness from the app's own work doesn't show it.
- App: Spotlight's web suggestions are not taken for the app: an app that is not installed is listed only there, and tapping it (or Return) opened a web search in the browser. Now the model is told the app is not on this iPhone.
- App: Chinese typed on the English keyboard is caught from the first read of what changed (the pinyin shows as plain letters), deleted and typed again after ctrl+space, without two more reads of the whole screen.
- App: the video decoder starts a new session as soon as the app goes to the background (tried again every 0.5 s for 3 s when iOS refuses it at first); the old one stopped giving frames there for about 10 s, which held up the first step. A tap that changes Spotlight (a keyboard candidate committing the pinyin) has its new results read before Return is pressed.
- App: a free-line call refused because the model service was saturated is asked again after 0.5 s instead of 3 s.
- App: a stopped run tells the free line who stopped it (the Stop button, the Live Activity, a notification, an answer to a question, or no answer in time).
- App: the free line gets each step's first token, image, change check, pointer check and after-gesture time, and the run's start time, as seconds only.
- iOS 27+: optional Screen Recording (Settings › Screen Source). The phone records its own screen with ScreenCaptureKit and the board only moves the pointer: no Wi-Fi or Screen Mirroring. Off in default builds (needs Xcode 27 and `IA_CAPTURE_BACKGROUND_MODE = screen-capture`); AirPlay is unchanged and stays the default. StopWatch firmware shows "Screen Recording on" when the app sends `o`. Based on PR #78 by await-ovo. Device checklist: [docs/screen-recording-device-test.md](docs/screen-recording-device-test.md).

## App 1.0.10.1 (TestFlight, a new build of 1.0.10)

**Significantly faster Chinese input.**

- Pinyin is typed in one go and read back once. A correct text is no longer deleted and typed again (a long text that shows only its end, the same message already in the chat, an OCR slip); only stray English letters or the keyboard's other candidate (西安 for 西岸) are retyped.
- A `type` that repeats part of the text just typed is skipped; `tap 发送` without quotes is understood (no extra model call).
- Runs end faster: the keyboard check after a run is read on the phone (0.2 s instead of 8-30 s), the planner's done check is off, no wait for a late on-device tree on slower phones, no 2.5 s stall at the start.
- Intents: a finished run keeps its plan; replayed steps carry this run's result; a "done" right after the app's own open is held once.
- Nothing is put on the clipboard at a run's start.
- Hermes Agent plugin (`integrations/hermes`, a portable Agent Plugins v1 package): the esp32agent MCP server (esp32agent 0.1.5) plus the manina skill. `hermes plugins install onehumanbeing/esp32-iphone-agent/integrations/hermes --enable`.

## App 1.0.10 (TestFlight)

- Agent: `collect WHAT max N` that stops on its count saves the result (README) and says where, as a list read to its end does.
- Agent: when the progress count is reached and the result written but the run goes on with another gesture, the planner looks once.
- Agent: a tap on a send button (发送 / Send / 发布 / Post / 回复 / Reply) is held once like Enter after a `type` that stopped part way, or when the same text was already sent; the same tap again goes through.
- Runs: a run that a guard gave up on ("stuck:") ends as `stall`, not `model_fail`; run_end also says which link the mouse and keyboard used (`transport`: usb / ble) and the longest run of gestures that changed nothing (`unchanged_max`).

## App 1.0.9 (TestFlight)

- iOS 16.4 minimum: iPhone 8 and iPhone X can run the app. On iPhones before iOS 17 the agent leaves an app through the AssistiveTouch menu (its button found on the screen) instead of the Home bar.
- Experimental M5Stack StopWatch board (Bluetooth): it shows the run (character, steps, time, the step's text), the yellow key pauses and resumes, two quick presses stop, help and confirms buzz until answered, a done task's answer shows on the screen, quick intents (the newest 5) start from the watch, hold yellow to talk. Updates from its own firmware channel; the app sends it the phone's time and what needs fixing (mirroring lost, iPhone locked).
- Agent: `collect WHAT max N` stops once the goal's N items are read.
- Agent: a screen back for the third time with no progress goes to the planner. Tab bar guard: a tab bar is a row of three or more short labels.
- Start: an app opened by its link (Fiverr added) waits for the screen only when iOS asked "Open in …?" first; a replay skips opening the app the link already opened, and looks for a step's label for at most 2.5 s.
- Learning: a tap's label is the text nearest it by its box (a search bar no longer learns the logo above it); the plan judge knows the app was opened before the plan.
- Runs: deleting a run removes it from its intents' history.
- Jev on the user's own key: one box for the element to tap.

## App 1.0.7 · firmware 0.2.6 (TestFlight)

- Agent: model replies are read off the main thread (board replies no longer wait behind them), and the app logs what the main thread runs when it stalls.
- Agent: a list whose cards already show every fact the goal asks for is read with `collect` from the top and never opened item by item; a collect stops once older items than the goal's dates show and nothing new does, and the run writes its result at once. One item with several facts (time, amount, start, end) stays one line. The first scroll back up after that is refused with the reason; a second goes through.
- Agent: higher ceilings: model output 8000 tokens (a reply still cut at its ceiling is asked once more with 16000), each up to 300 items, notes up to 1000 characters and 5000 items, 12 write-up rounds after the hand back.
- Agent: a done after only writing (snap, note, file, progress) ends the run, unless that file or snap failed.
- App: a free-line lease request that never reached the server is asked again (five times) and says the connection failed instead of "busy".
- App: Files lists every result once under Results and the rest under Files, and searches names and the text of README, notes, csv and txt. A swipe deletes at once (deleting the open folder from ⋯ still asks).
- Rebrand: Handsy is now Manina AI, at [manina.ai](https://manina.ai) (handsy.tech redirects there). App text,
  docs, plugin and skill names (`manina`, `manina-run-tasks`) and support addresses use the new name.
- The name is Manina AI everywhere (App Store has a different app called Manina).

- Firmware 0.2.6: `type` feeds the task watchdog per character and stops after a 4 s budget (or if USB suspends) instead of blocking long enough to reboot the board. The reply is `ok`, or `err typed N of M: budget|asleep` when it stops early. Status advertises `"tchunk":1`. Older firmware still answers `ok` only.
- Firmware 0.2.6 also: LAN mode with the LAN lock (on a home network only the owner phone mirrors; proof instead of the token, encrypted video), and a new IDR after a full GOP no longer resends the old tail (iPad rotation).
- App: iPad support (device family 1,2), LAN mode (the board joins the home Wi-Fi), shared prompts for iPhone and iPad.
- App: plain text is typed in chunks of at most 48 characters, so a long field stays inside that budget on current and older firmware. A partial reply is reported to the model as typing that stopped; the rest is not sent again in the same command.
- App: Settings › Unattended (off by default), also a parameter on the Run a Task shortcut. While it is on, help and confirm prompts wait two minutes and then skip or stop — a risky step is never approved on its own, and a passcode is never typed. A failed link check recovers instead of ending the run, model 429/5xx/timeouts back off for up to ten minutes, and a lost link is waited out for two hours. A locked phone (or USB asleep) is its own waiting state. Low Power Mode, low battery and a hot phone are surfaced; under 10% and unplugged the run waits. Learned Screen Mirroring taps can reopen mirroring from Control Center.
- App: each step records where its time went (screen, check, model before and after the first token, actions, other). The run review shows a bar on the step and a median summary; Diagnostics shows medians of the latest steps.
- App: a tap that already changed the screen at its target skips the pointer wiggle. The next look's image (and on-device tree, when that is on) is prepared while the change check runs. Settings › Look ahead (off by default) starts the next model request once the screen is nearly still, cancels it if the screen then moves, and checks the frame again before the gesture.
- App: the agent can save its results. `snap PATH [X1 Y1 X2 Y2]` saves the screen (or a box of it) as a .jpg and `file {JSON}` (the memory tool's view / create / str_replace / insert / delete / rename) works in Documents/memory, the folder MEMORY.md lives in; MEMORY.md itself stays the user's. A result is a folder with a Markdown README that shows its images.
- App: a Files tab (Agent, Runs, Files, Settings) shows Memory (MEMORY.md opens the Memory page; Results inside), Logs and the user's own files, with translated names. Markdown opens rendered with its images. The ⋯ menu adds a folder or a note, imports a file and exports a folder as a .zip; swipe to delete, touch and hold to rename. The app's own data and developer folders show only with Settings › Developer › Show developer files.
- App: logs live in Documents/logs (debug logs, crash trace, iOS diagnostics) and harness files in Documents/developer; both move there at the first launch. Logs › Send to Developer sends diagnostics, or mails the folder when this build has no upload. The harness scripts read the new paths and fall back to the old ones.
- App: runs, intents and files point at each other. A run records the intent that started it; its review lists the files it saved; an intent's page lists its last runs and their files; the Files tab lists results newest first with the run they came from, and a result folder opens that run. A .intent file shows its first intent's icon and name (stacked when it holds several); on its page the user picks which intents to add (Select All), and one that may already be saved asks before adding a second copy. Record (Home) and Import (Runs) lost their round background.
- App: a file or folder in the Files tab can be deleted by swiping, by touch and hold, or from the ⋯ menu inside it (results listed under a run too). Numbered images in a result folder are the user's to delete.
- App: a note that completes an earlier one (same item, same numbers, more detail) replaces it in notes.md, and at the end a note image the run also saved under another name is shared instead of kept twice.
- App: when the App Store has a newer version, Home shows a banner and a sheet asks once a day (Update / Later). A firmware release can name the oldest app it needs (`min_app`, `fw_release.py --min-app`); an older app does not offer it and asks for the app update instead.
- Agent: a `file view` of a path already viewed with no write since says it is unchanged and to finish or change it; looked-up text and file views show even before the first note. Done skips the planner's second look when the progress count is reached and the run wrote its result. `find` that starts with a recommendations feed on screen looks up the page instead of stopping.
- Agent: once the progress count is reached and a round only writes, the phone is handed back (input released, mirroring off, the island says "Writing up…") and the result is written with text-only model calls; screen actions are refused. If the write-up does not finish in 6 rounds or the model fails, the notes become README.md. A finished run that wrote its own result drops notes.md. The island shows Think from the start of a model call and Wait only after 8 s without an answer.
- App: Delete Folder sits in the folder's ⋯ menu (one menu, not two). Firmware lists fall back to handsy.tech while manina.ai is not reachable everywhere.
- Agent: a note's names (a shop, a hotel: parts with no digits) are checked against the page like its amounts; one the page does not show gets the same "check it" reply.
- App: an intent keeps the first plan of a run that worked and its next runs start from it without waiting for the planner, while the instruction is unchanged. Each plan is a Markdown file in Files › Plans (one per intent, never in intents or .intent files): it opens with the intent, whether the next run uses it and Edit. The app's plan goes when the instruction changes, a run with it fails or is marked wrong, after 7 days, or with Forget Saved Plan; a plan you edited stays until the instruction changes or you delete it. The agent cannot write the folder; unknown header lines from a newer app are kept.
- App + CLI: intent files are now `.intent` (`.esp32intent` still opens). A .intent file in the Files tab opens a preview with Add to Intents. Format: docs/intent-format.md.

## App 1.0.6 (build 17, TestFlight)

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
- Pointer: two far landings in a row off the same way calibrate again after 3 taps instead of waiting 15 (a changed
  tracking speed misses every tap alike); a landing's log line shows the span it moved by.
- App: the firmware check on Home runs at most once a minute, in a task a reloaded Home doesn't cancel. Some
  starts ran hundreds of cancelled checks a second on the main thread.
- App: with usage stats on, the app no longer crashes after the board restarts (after a firmware update, or
  when the app opens within 30 s of the board starting). The reboot event carried a value the stats sender could
  not encode; such events are now dropped instead.

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
