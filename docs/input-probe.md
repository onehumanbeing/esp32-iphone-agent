# Input probe: what another app can see of the board's taps

The input probe is a developer screen in the iOS app. It records what any third-party app on the same iPhone can
read about a tap (UIKit's `UITouch` and `UIEvent`, pointer hover) and about the phone (screen capture,
accessibility, GameController). It exists to measure how detectable the board is. It never changes how the board
taps.

Background: DingTalk's clock-in refused taps sent through the board (a BLE/USB HID mouse, with AssistiveTouch on and
AirPlay Screen Mirroring carrying the video) as "simulated taps". DingTalk's privacy policy says it collects
`UITouch`/`UIEvent` at clock-in. A static analysis lists `majorRadius`, `force`, `altitudeAngle`, `phase`, `tapCount`
and `event.type`. The probe reads all of those and a few more.

## Opening it

| From | How |
| --- | --- |
| The iPhone | Settings tab › Developer › **Input probe** (every build, including TestFlight; never on Home) |
| The harness inbox (Debug build) | `source harness/lib.sh; launch -probe board` |
| The board's `app <command>` relay (Debug build) | `app probe board` opens it with that label; `app probe save` writes the file and replies with the sample counts; `app probe close` dismisses it |
| A launch argument | `xcrun devicectl device process launch --device <id> <bundle id> -probe board` (read in every build; not tried on a TestFlight build) |
| A URL (Debug build only, like the other debug URLs) | `iphoneagent://probe?label=board` |

The screen has a tap pad at the top, a **Label** field, **Copy as JSON**, **Write file** and **Clear**, the live
signals, and one row per tap (newest first). Each tap is also written to `debug.log` as one `probe: #n [label] …`
line, so `harness/logs.sh` shows it.

**Write file** saves `Documents/input-probe.json`. From a development-signed build, pull it with
`source harness/lib.sh; app_copy from Documents/input-probe.json /tmp/input-probe.json` (or `xcrun devicectl device copy from`
with `--domain-type appDataContainer --domain-identifier <bundle id> --source Documents/input-probe.json`).
A TestFlight build can't be read by devicectl: use **Copy as JSON**, or the Files app (On My iPhone › the app).

## Protocol

Use the same iPhone, iOS version and app build for every condition. In each, set the label first, then make
20 single taps in the middle of the pad, about one a second. Then make 5 more taps to the left, right, top and bottom
of the pad. Write the file (or copy the JSON) after each condition; samples keep their own label, so one file can
hold every condition. Note which board you used (USB or Bluetooth) and which iPhone.

| | Label | Board | Mirroring | Who taps |
| --- | --- | --- | --- | --- |
| A | `finger+mirroring` | unplugged, Bluetooth off for it | on (any AirPlay receiver, or the board started with nothing plugged into the iPhone) | finger |
| B | `board` | connected, AssistiveTouch on | off | the board (agent or `harness/hid.sh` clicks) |
| C | `finger+board` | connected, AssistiveTouch on | off | finger |
| D | `board+mirroring` | connected, AssistiveTouch on | on | the board |

Optional: `finger` (no board, no mirroring) as a clean baseline, and B with AssistiveTouch off, if the board's
input works at all that way on the test iPhone.

What each pair separates:

- **A against D** is the real-world comparison: a person who happens to mirror their screen against the agent.
- **B against C** isolates the tap itself, with the phone in the same state (board connected) and only the source
  different.
- **A against C** shows what a connected board changes for a finger, such as the GameController mouse or the
  AssistiveTouch flag.
- **B against D** shows whether mirroring changes the taps or only the global signals.

## Reading the signals

### Per tap

| Field | What it is | How to read it |
| --- | --- | --- |
| `type` | `UITouch.type`: `direct`, `indirect`, `pencil`, `indirectPointer` | `indirectPointer` is a pointer click, a hard tell. Our app does **not** set `UIApplicationSupportsIndirectInputEvents`, so iOS hands it pointer clicks as `direct`. An app that sets the key to YES gets `indirectPointer` for the same click. Check the target app's Info.plist (see Limits). |
| `majorRadius`, `majorRadiusTolerance` | contact size in points and its accuracy | A finger's radius varies from tap to tap and often within a tap. A constant value over all of B or D, or one never seen in A or C, is a tell. Compare the `majorRadiusMin`/`Max` in the summary. |
| `force`, `maximumPossibleForce` | pressure, and its scale | On iPhones without 3D Touch both are 0 for a finger too, so they only separate sources on a 3D Touch iPhone (6s to XS) or if a click reports something else. |
| `altitudeAngle`, `azimuth` | stylus angles | A finger reports altitude π/2 (1.571). Different values for the board are a tell. |
| `phases`, `moved`, `pathPt` | the phase sequence, number of `moved` readings, distance travelled while down | A finger usually produces `moved` readings and a few points of travel, even on a tap. `began>ended` with 0 moved and path 0, every time, is a pattern a detector can learn. |
| `durationMs` | down → up time | Fingers spread out (often around 60–150 ms). A near-constant duration is a tell. Compare the median and the spread. |
| `tapCount` | UIKit's multi-tap counter | It should be 1 at one tap a second. Higher counts mean taps closer together than the double-tap window. |
| `eventType`, `eventSubtype` | `UIEvent.type` and subtype | Taps should be `touches`/`none`. Anything else is a tell. |
| `buttonMask` | `UIEvent.buttonMask`, the pointer buttons | 0 for a finger. Non-zero means the event came from a pointer. |
| `hoverBefore`, `hoverEvents` | whether a `UIHoverGestureRecognizer` on the pad saw the pointer since the previous tap | A finger can't hover on an iPhone. Any hover before a tap shows that a pointer is there. It counts only pointer movement over the pad. |
| `signals` | the global signals at the moment of the tap | So a file with mixed conditions stays readable. |

`dtMs` in each phase is the time since `began`. `x` and `y` are in the pad's points.

### Global (live, and stored with every tap)

| Field | API | How to read it |
| --- | --- | --- |
| `screenCaptured` | `UIScreen.isCaptured` (+ `capturedDidChangeNotification`) | True for AirPlay mirroring and screen recording. Any app can read it at any time, without a permission, whatever does the tapping. |
| `sceneCaptureState` | `UITraitCollection.sceneCaptureState` (iOS 17+) | The newer form of the same thing. |
| `screens` | `UIScreen.screens.count` | More than 1 means an extended (not mirrored) external display. |
| `assistiveTouch` | `UIAccessibility.isAssistiveTouchRunning` | The board needs AssistiveTouch for its pointer. Any app can read this flag. |
| `guidedAccess`, `voiceOver`, `switchControl` | `UIAccessibility` | Other accessibility modes, for context. |
| `mouseCurrent`, `mice` | `GCMouse.current`, `GCMouse.mice().count` | The board's HID mouse as GameController lists it. Any app that links GameController can see that a mouse is connected. Discovery is asynchronous, so a 0 right after the screen opens proves nothing; it updates on connect. |
| `keyboard` | `GCKeyboard.coalesced` | The board's HID keyboard, if it presents one. |
| `indirectInputEvents` | this app's `UIApplicationSupportsIndirectInputEvents` | `absent` in our build (see `type` above). |
| `ios` | `UIDevice.systemVersion` | |

`events` in the file lists every change of these signals with its time (mirroring started, mouse connected, …).
`summary` groups the samples by label: count, types, the radius range, the highest force, median duration, how many
had hover before, how many moved, and how many were taken while the screen was captured.

## Limits

- **`UIApplicationSupportsIndirectInputEvents` is fixed at build time.** Our app doesn't set it, so `type` shows what
  an app without the key sees. To learn what DingTalk sees, read its Info.plist from the IPA. If DingTalk sets the
  key, its taps from the board arrive as `indirectPointer` with a `buttonMask`, which the probe can't reproduce
  unless we add a test build with the key set. We didn't, because the key changes pointer handling across the whole
  app.
- **Only what UIKit hands an app is recorded.** Things a detector could combine with it are not measured here:
  CoreMotion (a finger tap jolts the accelerometer; a board click doesn't), the tap position's spread (the board
  lands on the same point at the same pixel every time), the time between taps, and server-side checks.
- **Hover is only seen over the pad.** A pointer that moved elsewhere and clicked without passing over the pad shows
  `hoverBefore: false`.
- The probe itself doesn't tell sources apart. It records the readings so we can compare them.
