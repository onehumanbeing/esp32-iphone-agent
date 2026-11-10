# Local Unicode input (experimental)

Related to [#135](https://github.com/onehumanbeing/esp32-iphone-agent/issues/135): this adds an on-device route for the **body of a `type` action**. It does not implement localized app discovery, IME detection or language-specific OCR. Those remain separate concerns, including the work in #136.

Printable ASCII keeps the existing HID path. Non-ASCII text, emoji, tabs and newlines go through one local Shortcuts transaction:

1. The app keeps the complete original text and a new request UUID, with a 20-second lease and a 65,536-byte UTF-8 limit. Notebook normalization is not used.
2. ESP32 invokes the configured keyboard command or long-presses the configured AssistiveTouch control. The Shortcut gets the one pending packet through an App Intent.
3. The Shortcut uses **Copy to Clipboard → Local Only**, reads its clipboard back, and acknowledges the same UUID and exact UTF-8 bytes. Merely fetching the packet is insufficient.
4. The app waits for a fresh frame resembling the original editor, rechecks the input connection, records the paste attempt and sends one Cmd+V. An acknowledgement failure does not permit another paste. The model must inspect the destination afterwards.

The app never reopens the destination app as part of this operation. A failed setup, trigger, acknowledgement or editor check reports a failure without silently transliterating the text. There is no ESP32 HTTP service, runtime computer bridge, custom keyboard or firmware change.

The App Intents use `LiveActivityIntent` to execute in the app process, with `openAppWhenRun` explicitly false. The deployment target stays iOS 18; actual iOS 18 runtime behavior still needs verification. AirPlay remains the normal video path.

## Build and setup

Use the normal README/CONTRIBUTING steps to build a device-signed app. Generate the identity-specific Shortcut as described in [`LocalCopyAssets/README.md`](../ios/IPhoneAgent/LocalCopyAssets/README.md), sign it with Apple's `shortcuts sign`, and rebuild to include it. The generated signed artifact is ignored by Git. A checkout without it still builds, but cannot offer that artifact for import.

On the iPhone, open **Settings → Unicode Input**:

1. Review and import Handsy Local Copy. Confirm that its copy action has Local Only enabled.
2. Run **Test Shortcut directly (no board input)**. Handle first-use Shortcuts permissions and return to see the result. This diagnostic has a 60-second lease and does not paste.
3. Connect ESP32's USB data port to the iPhone and keep BLE connected. Bind either a Full Keyboard Access command or AssistiveTouch Long Press to the Shortcut. For the latter, set the system long-press duration below 0.9 seconds and align the configured position with the floating control.
4. Run **Test Board Trigger (does not paste)**. A direct test does not certify the hardware trigger; only a successful hardware test enables this route.

USB status and BLE alone do not identify the USB host. The preflight also checks for the required phone-side keyboard/mouse. This catches a common wrong-host connection, but does **not** authenticate ESP32 among other connected accessories.

For an agent run, join the board's Wi-Fi and select **ESP32 Agent** in Screen Mirroring. Mirroring to a computer instead deprives the board of the video needed for the independent run. No computer service is needed during use.

## Device acceptance

Use a new disposable note, not an existing document or a message to another person. Focus an empty field and request one complete multiline input, for example:

```text
简体中文，繁體中文。
日本語 한국어 café é 🌍
line 3: "quotes" and spaces
```

Check exact characters, normalization-sensitive combining marks, emoji, line breaks, leading/trailing spaces and a second distinct payload. Test with an English system and without relying on a pinyin keyboard, then with another destination app. The stored `type` format accepts a JSON string (newlines as `\n` and tabs as `\t`) to preserve whitespace.

Also test missing/incorrect triggers, expired or wrong-ID receipts, clipboard replacement before read-back, cancellation, link loss, a moved editor and a lost HID acknowledgement. No automatic retry may send another paste. A new explicit `type` is a new operation; the agent must inspect existing content before requesting repair.

Receiving apps may still show iOS paste permissions. The agent pauses for recognized English or Simplified Chinese paste prompts and leaves the decision to the user. Other prompt languages are not covered by this detector. Copy success, a similar image and a HID acknowledgement do not prove insertion, focus or exact field contents. Do not report an end-to-end pass without inspecting the actual destination.

## Automated checks

```bash
python3 -m unittest discover -s tools -p 'test_*.py' -v
cd ios
xcodegen
xcodebuild test -scheme IPhoneAgent \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO -only-testing:IPhoneAgentTests
```

`LocalCopyTests` covers byte-exact receipts, expiry/cancellation, wrong-host preflight, JSON text preservation, action boundaries, unavailable-service behavior, duplicate paste after a lost acknowledgement/restore, permission handoff, ASCII routing, replay handoff and releasing a long press after cancellation or a lost acknowledgement. Generator tests check the seven local actions, read-back wiring, UUID references and binary plist encoding; the iOS CI job runs them too. Neither suite substitutes for a signed Shortcut and a real iPhone + board pass.

Based on ESP32 iPhone Agent by Henry Yuan. Keep the root LICENSE and NOTICE; credit the original project in derived demos and posts.
