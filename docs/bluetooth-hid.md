# Bluetooth mouse and keyboard

[简体中文](bluetooth-hid.zh-CN.md)

All builds receive app commands over Bluetooth. The standard firmware sends mouse and keyboard input to the iPhone over USB. A BLE HID build sends mouse, keyboard and consumer-control reports over Bluetooth to the same iPhone that sent the command. The command connection and the input connection have separate readiness checks.

## What each part does

| Part | Responsibility |
| --- | --- |
| Shared BLE HID firmware | Pairs and authorizes the iPhone, sends HID reports and checks their destination and connection session. A dropped connection invalidates queued commands; a new session starts with no keys or buttons held. Select it with `HID_TRANSPORT_BLE` on a supported board. |
| App | Reads `hid` for Bluetooth input readiness, guides pairing and handles pauses, recovery and recalibration when input disconnects. The `board` field identifies the hardware. |
| Note 4 adapter | Sets up power, peripheral pins, the battery ADC and discharge curve, and the 16 MB flash layout. See the [Note 4 board guide](note4-bluetooth.md). |
| Firmware updates | Each target has its own build output and image checks. The published USB update channel serves only standard USB images. A BLE HID target would need a compatible image to update over the air. |

Screen capture still uses AirPlay over Wi-Fi. The BLE HID build adds wireless input only. It does not add e-paper or voice features.

## Build the firmware

Run the matching command from the repository root. Both wireless targets require `--build-only`.

| Target | Command | Output |
| --- | --- | --- |
| Standard 8 MB USB | `hardware/flash.sh --build-only` | `hardware/build/` |
| Standard 8 MB BLE HID | `hardware/flash.sh --ble-hid --build-only` | `hardware/build/ble-hid/` |
| Note 4 BLE HID | `hardware/flash.sh --note4 --build-only` | `hardware/build/note4/` |

The standard BLE build uses the reference ESP32-S3 configuration with 8 MB flash and OPI PSRAM. It lets you build BLE HID independently of Note 4. Before flashing, check that the chip, flash, PSRAM and partition layout match your board. Make a full flash backup, then follow the board's wired installation procedure. The web installer and in-app updater distribute only the standard USB firmware.

## Pair and verify

1. Power on the board with the matching BLE firmware. Within the three-minute pairing window, select the board in the app and confirm the iOS pairing request. Its name begins with `ESP32 Agent` by default, or the name you passed to `--name`. The name starting with `CLI` is for the computer.
2. On the iPhone, open **Settings → Accessibility → Touch → AssistiveTouch** and turn it on. Under **Devices**, select the same board and set **Button 2** to **Home**.
3. In the app's diagnostics, check both the command connection and `hid: ok` before starting a task. The latter means the Bluetooth input link is ready.
4. Calibrate the pointer and verify that it moves, clicks and types on the iPhone. If an older experimental firmware left a stale pairing, forget the old device in iOS Settings and pair again.
5. Use [Quick start](../README.md#quick-start) to set up Wi-Fi and AirPlay and check that screen capture works.

Builds, unit tests and protocol simulations exercise the code paths. On each target, also test first pairing, two hosts competing for input, reconnection and input on the phone itself.
