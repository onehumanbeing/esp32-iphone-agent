# Screen Recording (iOS 27+): device test checklist

From iOS 27 the app can record the phone's own screen with ScreenCaptureKit instead of receiving it through the
board's AirPlay mirroring. The board then only moves the pointer (USB or Bluetooth HID), so no Wi-Fi, hotspot or
Screen Mirroring is needed. AirPlay stays the default and the only choice before iOS 27.

Based on PR #78 by await-ovo.

## How the source is chosen

`CaptureBackend.resolve` (ios/IPhoneAgent/Video/CaptureBackend.swift) picks Screen Recording only when all of
these hold, and AirPlay otherwise:

| Condition | Where it comes from |
|---|---|
| iOS 27 or later | `#available(iOS 27.0, *)` |
| Built with an SDK that has ScreenCaptureKit for iOS (Xcode 27+) | `canImport(ScreenCaptureKit)`; older Xcodes compile the feature out |
| Screen recording allowed on this phone | `SCContentSharingPicker.shared.isAvailable` (Screen Time can forbid it) |
| The build declares the `screen-capture` background mode | `UIBackgroundModes` in the built Info.plist (`IA_CAPTURE_BACKGROUND_MODE`) |
| An iPhone, not an iPad | iPads keep AirPlay: their per-orientation calibration needs the mirrored picture's shape |
| The user chose Screen Recording | Settings › Screen Source (saved as `captureBackend`) |

The Settings row only appears when the first five hold. A saved choice that loses support (another build, Screen
Time) falls back to AirPlay and is kept for later.

The firmware plays no part in the choice. Every firmware moves the pointer the same way. The app gives the
StopWatch one extra hint, `"o":1` in the `ui` line, which older firmware skips.

## Building a test build

The default build declares no `screen-capture` mode, so it behaves exactly like today on every iOS version.
To test the feature:

1. Use Xcode 27 or later. With Xcode 26 the feature is compiled out.
2. In `ios/Config/Local.xcconfig` (not committed), set:
   ```
   IA_CAPTURE_BACKGROUND_MODE = screen-capture
   CODE_SIGN_ENTITLEMENTS = IPhoneAgent/IPhoneAgentScreenCapture.entitlements
   ```
   For fastlane: `IA_SCREEN_CAPTURE=1 fastlane beta`.
3. Make sure the App ID has the Screen Recording capability (`com.apple.developer.screen-recording`) and the
   profile includes it. If Xcode can't provision it, drop the `CODE_SIGN_ENTITLEMENTS` line and record what
   happens (see "Unknowns").

## The matrix

"New app" = this branch. "Old app" = the current TestFlight build. "New firmware" = this branch's StopWatch
firmware (reads `o`). Firmware is the same for HID boards (hid_bridge, dual-HID): nothing changed for them.

| # | iOS | App build | Firmware | Expected |
|---|---|---|---|---|
| 1 | 18–26 | new, default | old | AirPlay exactly as today. No Screen Source row in Settings. |
| 2 | 18–26 | new, default | new | Same as 1. StopWatch shows Wi-Fi / Mirroring as today. |
| 3 | 18–26 | new, capture build | old / new | Same as 1. No Screen Source row (iOS too old). |
| 4 | 27+ | old | old / new | AirPlay as today. New firmware shows Mirroring (no `o` sent). |
| 5 | 27+ | new, default | old / new | AirPlay. No Screen Source row (no background mode). |
| 6 | 27+ | new, capture build, AirPlay chosen | old / new | AirPlay as today. Row present, set to AirPlay. |
| 7 | 27+ | new, capture build, Screen Recording | old | Runs work with the board on USB or Bluetooth only, no Wi-Fi. StopWatch shows Mirroring off (it skips `o`); that is cosmetic. |
| 8 | 27+ | new, capture build, Screen Recording | new | As 7. StopWatch status page: "Screen Recording on"; idle dots: Bluetooth, Wi-Fi, Recording (green). Character alone when linked, without Wi-Fi. |
| 9 | 27+ iPad | new, capture build | any | AirPlay. No Screen Source row. |
| 10 | 27+ | capture build, Screen Time forbids recording | any | AirPlay. No Screen Source row. |

## Steps for each Screen Recording cell (7, 8)

**Settings and home**
- [ ] Settings › Screen Source shows AirPlay and Screen Recording. The footer changes with the choice.
- [ ] Choosing Screen Recording: the home chip "Mirroring" becomes "Screen Recording" (green). Tapping it opens Settings.
- [ ] The row is disabled while a run, a demonstration or a calibration is going.
- [ ] Onboarding (reset `onboarded`) skips the "See the screen" step.

**Consent**
- [ ] Starting a task shows the system screen-sharing picker. Pick the whole screen (Display).
- [ ] Picking only this app: the run stops with "Share the entire screen, not only this app. Start the task again."
- [ ] Cancelling the picker: "Screen sharing was cancelled…". No run starts; Home is usable.
- [ ] The system recording indicator (status bar / Dynamic Island) shows during the run and goes away after it.
- [ ] Each new task asks again (the share ends with the run).
- [ ] Starting a run from Siri or a Shortcut while the app is in the background: blocked with "Open the app to allow screen sharing."

**Background capture (the main risk)**
- [ ] A task that opens another app (Settings, Safari, WeChat) runs to the end. Frames keep coming while the agent app is in the background.
- [ ] Lock the phone mid-run: the run pauses with the locked warning, as with AirPlay.
- [ ] In the device log, look for `capture: onDevice (…)` at launch and no `SCStreamErrorDomain -3824` (missing background mode).
- [ ] Let a run go 10+ minutes in another app: no stop, no `-3817` (user stopped) unless you stopped it.
- [ ] Stop sharing from Control Center mid-run: the run pauses with "Screen sharing stopped…" and does not loop.

**Pointer, calibration, demonstration**
- [ ] Auto calibration works with Screen Recording (it asks for sharing itself when no run is going).
- [ ] Recording a demonstration works and stops sharing at its end.
- [ ] Board unplugged / Bluetooth lost mid-run: the run pauses (the capture's `live` follows the board link) and resumes when it is back.

**StopWatch (cell 8)**
- [ ] Status page row 4 reads "Screen Recording on" / "录屏 已开启", green.
- [ ] Idle with Bluetooth linked and no Wi-Fi: the character alone (linked), not the dots.
- [ ] Switching back to AirPlay in Settings: the watch shows Mirroring again within a second.

**Cost**
- [ ] Note battery drop and phone temperature over a 10-minute run, vs. AirPlay.

## Unknowns to settle on the first device test

1. Whether `com.apple.developer.screen-recording` is needed and can be provisioned for this team. Apple's sample
   declares it; a forum report says a Personal Team can't provision it.
2. Whether App Store Connect accepts `UIBackgroundModes: screen-capture`. A September 2026 forum report (Xcode
   27.0) says the upload was rejected as an invalid value. Try one TestFlight upload of the capture build early.
   If it is rejected, the feature stays off in store builds; nothing else changes.
3. Whether a backgrounded capturing app stays alive for a long run. One forum report says it was suspended even
   with the mode declared.
4. The picker's `filter.style` check at runtime (whole screen vs. one app).
5. "Listen to phone audio" uses AirPlay audio, so it is not available with Screen Recording.

## Rollback

- Per phone: Settings › Screen Source › AirPlay. The next run uses mirroring.
- Per build: leave `IA_CAPTURE_BACKGROUND_MODE` at its default (`bluetooth-central`) and don't set
  `IA_SCREEN_CAPTURE`. The build then never offers Screen Recording.
- StopWatch firmware: the `o` key only changes what the watch shows; older firmware ignores it. Flash or OTA the
  previous firmware if the display is wrong.

## References

- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- Capturing screen content on iOS (Apple sample; declares `com.apple.developer.screen-recording` and
  `UIBackgroundModes` `screen-capture`): https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- Configuring background execution modes ("The app captures and streams screen content while in the background"):
  https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- App Review Guidelines 2.5.1, 2.5.4, 2.5.14, 5.1.1, 5.1.2: https://developer.apple.com/app-store/review/guidelines/
- Provisioning the entitlement: https://developer.apple.com/forums/thread/856067
- Background capture scope: https://developer.apple.com/forums/thread/857942
- App Store Connect and `screen-capture`: https://developer.apple.com/forums/tags/screencapturekit (thread
  "iOS 27: ScreenCaptureKit requires UIBackgroundModes 'screen-capture', but App Store Connect rejects that value")
