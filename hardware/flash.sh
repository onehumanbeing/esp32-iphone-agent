#!/usr/bin/env bash
# Build and flash the board (needs arduino-cli and the esp32 core 3.3.x).
# Usage: hardware/flash.sh [port] [--debug] [--sta] [--build-only]
#   --debug       log commands and the AirPlay handshake on USB serial
#   --sta         test build: join the Wi-Fi in hid_bridge/secrets.h instead of opening a hotspot
#   --build-only  compile only (prints flash/RAM usage)
#   --ap-tune     A/B build: hotspot on a 20 MHz channel with 300 TU beacons (more airtime for BLE)
# BLE host: h2zero NimBLE-Arduino (arduino-cli lib install "NimBLE-Arduino"); its buffer sizes live in
# hid_bridge/nimble_cfg.h, force-included into every C/C++ file below.
# A running bridge is a TinyUSB device, so it is first kicked into the ROM
# bootloader with a 1200-baud touch; a blank board is flashed directly.
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB"
ports() { for p in /dev/cu.usbmodem* /dev/ttyACM*; do [[ -e $p ]] && echo "$p"; done; return 0; }
PORT="" DEFS="" BUILD_ONLY=0
for a in "$@"; do
  case $a in
    --debug) DEFS+=" -DDEBUG_SERIAL=1" ;;
    --sta) [[ -f hid_bridge/secrets.h ]] || { echo "--sta needs hid_bridge/secrets.h (see secrets.example.h)"; exit 1; }
           DEFS+=" -DSTA_FROM_SECRETS=1" ;;
    --build-only) BUILD_ONLY=1 ;;
    --ap-tune) DEFS+=" -DAP_TUNE=1" ;;
    *) PORT=$a ;;
  esac
done
[[ $PWD != *" "* ]] || { echo "the -include path below cannot contain spaces: $PWD"; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
FLAGS=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")

arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build hid_bridge
(( BUILD_ONLY )) && exit 0
BEFORE=$(ports)
PORT=${PORT:-$(head -n 1 <<<"$BEFORE")}
[[ -n $PORT ]] || { echo "no board found (looked for /dev/cu.usbmodem* and /dev/ttyACM*)"; exit 1; }
stty -f "$PORT" 1200 2>/dev/null || stty -F "$PORT" 1200 2>/dev/null || true
# The ROM bootloader may come back under a new name. Follow the port that appeared after the
# reset rather than the first one listed, so other connected boards are never picked up.
new_ports() { comm -13 <(sort <<<"$BEFORE") <(ports | sort); }
for _ in $(seq 20); do sleep 0.5; [[ -n $(new_ports) ]] && break; done
sleep 1  # let the ROM bootloader's serial come up
NEW=$(new_ports)
case $(grep -c . <<<"$NEW" || true) in
  0) [[ -e $PORT ]] || { echo "$PORT is gone after the reset and no new port appeared"; exit 1; } ;;
  1) PORT=$NEW ;;
  *) echo "several ports appeared after the reset, not guessing:" $NEW; exit 1 ;;
esac
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir build hid_bridge
