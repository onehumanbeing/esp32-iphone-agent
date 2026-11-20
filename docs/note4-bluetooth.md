# Zectrix Note 4 board adapter

[简体中文](note4-bluetooth.zh-CN.md)

Note 4 is a battery-powered ESP32-S3 device with a 4.2-inch monochrome e-paper display. Its firmware uses the [shared Bluetooth mouse and keyboard support](bluetooth-hid.md). The adapter supplies the power, pin, battery and partition settings for this board.

## What is specific to Note 4

- Keeps power on when running from the battery and sets idle peripheral pins to avoid noise and excess power draw.
- Reads battery voltage from the board's ADC pin and estimates charge using the Zectrix reference curve.
- Builds a separate image for 16 MB flash, OPI PSRAM and the matching partition layout.
- Reports `board: note4` to identify the hardware. The separate `hid` field reports Bluetooth input capability and readiness.

The adapter does not implement the stock e-paper display or voice to-do features. Screen capture uses the project's existing AirPlay connection over Wi-Fi.

## Build the firmware

From the repository root, run:

```sh
hardware/flash.sh --note4 --build-only
```

The script builds the image in `hardware/build/note4/` without flashing it. Use a wired connection for the first installation. Verify the physical board, make a full flash backup and check its partition table. The web installer and the in-app USB firmware updater serve the standard board only.

## Connect and check

Follow the [shared pairing and verification steps](bluetooth-hid.md#pair-and-verify). In addition to pairing, reconnection and actual phone input, check battery-only operation, battery readings and recovery after power loss on Note 4.
