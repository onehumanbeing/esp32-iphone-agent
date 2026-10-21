#!/usr/bin/env bash
# Build and flash the HID bridge (needs arduino-cli and the esp32 core). Usage: hardware/flash.sh [port] [--debug]
# On Windows run it from Git Bash; the port is a COM port (COM5).
# A running bridge is a TinyUSB device, so it is first kicked into the ROM
# bootloader with a 1200-baud touch; a blank board is flashed directly.
set -euo pipefail
cd "$(dirname "$0")"
FQBN=${FQBN:-"esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M"}
source ./ports.sh
port() { serial_port 303A /dev/cu.usbmodem* /dev/ttyACM*; }
PORT=${1:-$(port)}
FLAGS=(--build-property "compiler.cpp.extra_flags="); [[ "${2:-}" == --debug ]] && FLAGS=(--build-property "compiler.cpp.extra_flags=-DDEBUG_SERIAL=1")

arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build hid_bridge
OLD=$PORT
touch_1200 "$PORT"
for _ in $(seq 20); do sleep 0.5; PORT=$(port); [[ -n "$PORT" && "$PORT" != "$OLD" ]] && break; done
sleep 1  # let the ROM bootloader's serial come up
PORT=$(port)
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir build hid_bridge
