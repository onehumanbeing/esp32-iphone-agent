# Siri AI integration (developer preview)

This is an early pass at letting Siri call ESP32 Agent as a tool, built against Apple's Siri AI Developer
Preview (iOS, iPadOS and macOS 27.3 beta, announced 3 November 2026). The preview only works in
development-signed builds and internal TestFlight; it is not in App Store builds.

## What is here

| Piece | Where | State |
|---|---|---|
| Tool intents: run a task, stop the run, check the run, replay a run | `ios/IPhoneAgent/App/SiriToolIntents.swift` | written, not compiled |
| Generable request entity, run entity with authenticated properties | same file | written, not compiled |
| App skill for multi-step guidance | `ios/IPhoneAgent/Skills.skillsbundle/Skills/handsy-run-tasks/SKILL.md` | written, not compiled |
| View annotations on the Runs list and the Home run card | `ios/IPhoneAgent/UI/RunViewAnnotations.swift` | written, not compiled |

**Build status.** The code written here was authored on a Linux machine with no Xcode, so the preview
code itself — everything inside `#if HANDSY_SIRI_AI` — has not been compiled or run, and no Siri
behaviour has been observed. What CI does cover is the flag-off build: with `HANDSY_SIRI_AI` unset the
app still builds and its tests pass on Xcode 26.6, which includes `SiriToolConsent`, the `.openRun`
request and its handler, and the annotation call sites. Expect compile errors in the preview code the
moment the flag is turned on. See "Checking it" below.

## Turning it on

The Siri AI APIs (`@AppIntent(.tool)`, `@AppEntity(.generable)`, `authenticationPolicy` on an entity
property) ship with the iOS 27.3 SDK. The code sits behind the `HANDSY_SIRI_AI` compilation condition
so the app keeps building with the current toolchain while the preview is evaluated.

1. Open `ios/IPhoneAgent.xcodeproj` in Xcode 27.3 or later.
2. Select the `IPhoneAgent` target, Build Settings, and add `HANDSY_SIRI_AI` to
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for both Debug and Release.
3. Build for a device that supports Apple Intelligence.

`project.yml` lists `Skills.skillsbundle` so regenerating the project keeps it in Copy Bundle
Resources. Xcode only validates and compiles the bundle with the 27.3 toolchain; on an older Xcode it
is copied but gives Siri nothing.

## What each tool does

Every tool goes through the entry points the app already uses, so a run started by Siri is the same
run: same Live Activity, same recording, same review at the end.

- **Run a task on this iPhone** takes one sentence and calls the same start path as the Shortcuts
  action. It asks for device authentication before it starts.
- **Stop the run** calls the same stop path as the Live Activity's Stop button. It stays allowed on a
  locked phone, because stopping takes nothing away.
- **Check the run** returns the same status lines the status snippet shows.
- **Replay a run** opens the recorded run in the review screen, the same screen a tap on a Runs row
  opens.

## Consent

The app's consent gate is untouched. In a store build the network layer already refuses every
request to a model host the person has not agreed to, and that check still applies to anything a tool
starts. On top of that, the run tool checks the same recorded agreement up front so Siri can say "open
the app and allow this" instead of letting a run start and fail part-way. Builds from source have no
gate, exactly as in the app.

## Checking it

On a Mac with Xcode 27.3 and an Apple Intelligence device:

1. Build and run from Xcode (not the Simulator).
2. Hold the Side button and say, for example, "Find cafés near me in Google Maps in ESP32 Agent".
3. Check the run starts, the Live Activity appears, and "Stop" stops it.
4. Ask "How is the run going in ESP32 Agent" and compare the reply with the app's status.
5. With the Runs list on screen, ask Siri to replay the run you are looking at.
6. Open Shortcuts and confirm the four actions appear and run.

Useful Apple references: the App Intents documentation for `ToolIntent`, `GenerableEntity` and
"Orchestrating complex actions with app skills", plus WWDC26 session 240 ("Build intelligent Siri
experiences with App Schemas") and 343 ("Explore advanced App Intents features for Siri and Apple
Intelligence").

Questions: support@handsy.tech
