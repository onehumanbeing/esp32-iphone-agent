# HID bridge over Bluetooth LE (ESP32-C3 or classic ESP32)

This is a drop-in replacement for `hid_bridge` (which needs an ESP32-S3 on USB). The board pairs with the iPhone as a Bluetooth mouse and keyboard. It still talks to the server over Wi-Fi with the same TCP line protocol, so the server does not change. When the phone is not paired or connected, commands get the reply `err ble not connected` (`ping` still answers `ok`).

Library: NimBLE-Arduino 2.5.1 (h2zero), on the esp32 Arduino core 3.3.x. The mouse and keyboard HID descriptor is in `ble_hid.h`.

## Setup and flashing
1. Install arduino-cli, then the esp32 core and the library:
   ```
   arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
   arduino-cli core update-index && arduino-cli core install esp32:esp32
   arduino-cli lib install NimBLE-Arduino
   ```
2. Copy `secrets.example.h` to `secrets.h` and fill in your Wi-Fi details and the server IP and port.
3. Plug in the board and flash it:
   - ESP32-C3: `hardware/flash_ble.sh` (add `--debug` to log commands over USB serial)
   - Classic ESP32 (WROOM-32E): `hardware/flash_ble.sh --classic`
   - You can pass a port too, for example `hardware/flash_ble.sh /dev/ttyACM0`. If a C3 won't upload, hold BOOT while you plug it in. On Windows, run it in Git Bash and pass a COM port if needed (`COM5`); CP210x and CH340 boards may need the vendor's USB driver.

## Pairing with the iPhone
1. On the iPhone, open Settings > Bluetooth and tap **iPhone Agent HID**. Accept the pairing request.
2. Turn on Settings > Accessibility > Touch > AssistiveTouch. A pointer should appear.
3. Run the server (`python -m hidagent`). The board connects and sends `hello`.
4. If you want to pair again, use Forget This Device on the phone and reset the board.

## Known caveats
- **Pointer speed:** Bluetooth reports aren't spaced as evenly as USB ones. If the agent overshoots or undershoots taps, change `STEP` and `STEP_MS` in `hid_bridge_ble_c3.ino`, or the AssistiveTouch Tracking Speed slider. Keep Tracking Speed fixed after the server is calibrated.
- **iOS pointer acceleration:** iOS speeds the pointer up based on how fast it moves. Constant pace moves keep that predictable, but a move can still land a few pixels off. `home` slams into the top left corner to reset the position.
- **Wi-Fi and BLE share one radio:** commands can take a few ms longer than on USB.
- **Lock screen:** when the phone is locked, the BLE link may drop, and you'll see `err ble not connected` until the phone reconnects.
- **Flash size:** the build uses 93% of the default partition on the C3, so the flash script uses the huge_app partition.
- **Boot loop with `partition 0 invalid magic number` (C3):** the default C3 bootloader is built for QIO flash and switches the flash chip into quad mode on its own, even if you flash with `--flash-mode dio`. Many C3 boards can't read flash that way. The build now uses `FlashMode=dio,FlashFreq=40`, which selects the DIO bootloader. Rebuild, run `esptool --chip esp32c3 --port PORT erase-flash`, then flash `build_ble/hid_bridge_ble_c3.ino.merged.bin` at `0x0`.
- **Classic ESP32:** the code is the same; just add `--classic`. It has no native USB, so serial goes through its USB to UART chip.
