# One image, USB HID or BLE HID

`hardware/flash.sh --dual-hid` builds one image for the standard 8 MB board that carries both the USB HID and the
BLE HID input. The mode is chosen in the app and kept on the board, so images differ only by hardware (flash,
PSRAM, partitions, board peripherals), not by how the mouse reaches the phone.

```bash
hardware/flash.sh --dual-hid               # flashed over USB like the standard build; starts in USB mode
uv run hardware/tools/hidmode.py [usb|ble] # show or switch over USB serial (board on the Mac), works in both modes
harness/hid.sh "hidmode ble"               # the same through the Debug app over BLE
```

In the app: **Settings › Board › Input** (shown for a board that reports `hidm`). Switching restarts the board;
Screen Mirroring has to be started again. For Bluetooth, pair the board once in Settings › Accessibility › Touch ›
AssistiveTouch › Devices › Bluetooth Devices; for USB, plug it into the phone's USB-C port.

## How it works

- `hidmode` answers `ok usb` or `ok ble`. `hidmode usb|ble` saves the mode in NVS, answers `ok <mode>, restarting`
  and restarts the board half a second later. A board that never chose runs USB. The CLI cannot send it.
- The mode is read once at boot and stays fixed until the next restart. The status carries `hidm` (`usb`/`ble`);
  `hid` appears only in BLE mode, which is how the app tells a wireless board.
- **USB mode**: the BLE side is the standard firmware's (no HID service, no HID in the advertisement: a phone that
  pairs a Bluetooth keyboard hides its own).
- **BLE mode**: the HID service, advertisement and single-phone binding of `--ble-hid`. The USB HID interfaces
  stay in the USB descriptor but nothing is sent on them: with `CDCOnBoot=cdc` the core runs `USB.begin()` in
  `app_main()` before `setup()`, and TinyUSB refuses an interface added later, so which interfaces exist cannot
  depend on a mode read from NVS (created in `setup()`, they never reached the phone).
- The HID service is registered after the app's services, so the app's handles are the same in both modes. On the
  first boot after a switch the board sends a Service Changed indication to every phone that connects.
- Over BLE, Home is the swipe from the home bar (iOS ignores AC Home there), and homing pushes up fewer reports so
  iPadOS does not open Notification Center (the app tunes the count per iPad: `Pointer.homeUp`, `HomeTuning`).
- The image is marked `ESPA:dual-8m`: the USB OTA channel refuses it, and it does not run the OTA server yet.
  Update it over the wire.

## Checked on

iPhone 15 and iPad Air M3, a XIAO ESP32-S3 and a two-port ESP32-S3 board (2026-11-19/20): switching both ways
from the app link and over serial, the Bluetooth pointer reconnecting after a switch without pairing again, the
app reconnecting without unpairing, calibration and runs in both modes, the USB state following the cable.

Not covered yet: Note 4 (its own image), OTA for this image, a release channel per hardware.
