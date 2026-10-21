#!/usr/bin/env bash
# Build and flash the BLE HID bridge. Usage: hardware/flash_ble.sh [port] [--debug] [--classic]
# Default target ESP32-C3 (USB CDC on boot). --classic targets a classic ESP32 (ESP32-WROOM-32E).
# On Windows run it from Git Bash; the port is a COM port (COM5).
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32c3:CDCOnBoot=cdc,PartitionScheme=huge_app,FlashMode=dio,FlashFreq=40"
PORT=""; FLAGS=(--build-property "compiler.cpp.extra_flags=")
for a in "$@"; do case $a in
  --debug) FLAGS=(--build-property "compiler.cpp.extra_flags=-DDEBUG_SERIAL=1") ;;
  --classic) FQBN="esp32:esp32:esp32:PartitionScheme=huge_app" ;;
  *) PORT=$a ;;
esac; done
[[ -f hid_bridge_ble_c3/secrets.h ]] || { echo "copy hid_bridge_ble_c3/secrets.example.h to secrets.h and fill it in"; exit 1; }
source ./ports.sh  # Windows: ESP32-C3 native USB, CP210x, CH340 or FTDI bridges
[[ -n $PORT ]] || PORT=$(serial_port '303A|10C4|1A86|0403' /dev/cu.usbmodem* /dev/cu.usbserial* /dev/cu.SLAB* /dev/ttyACM* /dev/ttyUSB*)
[[ -n $PORT ]] || { echo "no serial port found; pass one"; exit 1; }
arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build_ble hid_bridge_ble_c3
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir build_ble hid_bridge_ble_c3
