#!/usr/bin/env bash
# Build and flash the board (needs arduino-cli and the esp32 core 3.3.x).
# Usage: hardware/flash.sh [port] [--debug] [--sta] [--build-only]
#   --debug       log commands and the AirPlay handshake on USB serial
#   --sta         test build: join the Wi-Fi in hid_bridge/secrets.h instead of opening a hotspot
#   --build-only  compile only (prints flash/RAM usage)
#   --name NAME   the board's name in Screen Mirroring and Bluetooth (one word; default ESP32 Agent)
#   --abs         USB absolute mouse instead of the relative one (needs AssistiveTouch; the app skips calibration)
#   --no-audio    mirroring only: do not advertise AirPlay audio (keeps audio on the iPhone speaker)
#   --ap-tune     A/B build: hotspot on a 20 MHz channel with 300 TU beacons (more airtime for BLE)
#   --note4       build BLE HID for the Note 4 (build only)
#   --ble-hid     build BLE HID for the standard 8 MB board (build only)
#   --stopwatch   build BLE HID for the M5Stack StopWatch, with its screen and buttons (build only, experimental).
#                 Needs M5Unified and M5GFX 0.2.x: arduino-cli lib install --no-deps "M5Unified@0.2.29" "M5GFX@0.2.36"
#                 (without --no-deps it pulls M5GFX 0.3.0, which changed the display rotation).
#   --dual-hid    the standard 8 MB board with USB and BLE HID in one image, chosen in the app (Settings > Board >
#                 Input) or with `hidmode usb|ble`; docs/hid-mode-switch.md. Flashes like the USB build.
# BLE host: h2zero NimBLE-Arduino (arduino-cli lib install "NimBLE-Arduino"); its buffer sizes live in
# hid_bridge/nimble_cfg.h, force-included into every C/C++ file below.
# A running bridge is a TinyUSB device, so it is first kicked into the ROM
# bootloader with a 1200-baud touch; a blank board is flashed directly.
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB"
ports() { for p in /dev/cu.usbmodem* /dev/ttyACM*; do [[ -e $p ]] && echo "$p"; done; return 0; }
PORT="" DEFS="" BUILD_ONLY=0 OUTPUT=build NOTE4=0 STOPWATCH=0 BLE_HID=0 DUAL=0 ABS=0 NAME_NEXT=0
for a in "$@"; do
  if (( NAME_NEXT )); then
    [[ $a =~ ^[A-Za-z0-9]+$ ]] || { echo "--name takes one word of letters and digits"; exit 1; }
    DEFS+=" -DBOARD_NAME=$a"; NAME_NEXT=0; continue
  fi
  case $a in
    --note4) NOTE4=1; BLE_HID=1 ;;
    --stopwatch) STOPWATCH=1; BLE_HID=1 ;;
    --ble-hid) BLE_HID=1 ;;
    --dual-hid) DUAL=1 ;;
    --name) NAME_NEXT=1 ;;
    --debug) DEFS+=" -DDEBUG_SERIAL=1" ;;
    --sta) [[ -f hid_bridge/secrets.h ]] || { echo "--sta needs hid_bridge/secrets.h (see secrets.example.h)"; exit 1; }
           DEFS+=" -DSTA_FROM_SECRETS=1" ;;
    --build-only) BUILD_ONLY=1 ;;
    --ap-tune) DEFS+=" -DAP_TUNE=1" ;;
    --abs) ABS=1 ;;
    --no-audio) DEFS+=" -DNO_AIRPLAY_AUDIO=1" ;;
    --crash-test) DEFS+=" -DOTA_CRASH_TEST=1" ;;  # build only, then push it with ota_push.py
    --small-gop) DEFS+=" -DGOP_CAP_KB=256" ;;  # test build: the GOP fills (freezes) within minutes
    --*) echo "Unknown build option: $a" >&2; exit 1 ;;
    *) PORT=$a ;;
  esac
done
if (( NOTE4 && STOPWATCH )); then
  echo "--note4 and --stopwatch are different boards; pick one." >&2
  exit 1
fi
if (( DUAL )); then
  if (( BLE_HID || ABS )); then
    echo "--dual-hid is its own target for the standard 8 MB board; it cannot be combined with --ble-hid, --note4, --stopwatch or --abs." >&2
    exit 1
  fi
  DEFS+=" -DHID_DUAL=1 -DHID_TRANSPORT_BLE=1"; OUTPUT=build/dual-hid
fi
if (( ABS )); then
  if (( BLE_HID )); then
    echo "--abs requires USB HID and cannot be combined with --ble-hid, --note4 or --stopwatch." >&2
    exit 1
  fi
  DEFS+=" -DABS_POINTER=1"
fi
if (( NOTE4 )); then
  FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB"
  DEFS+=" -DZECTRIX_NOTE4=1"; OUTPUT=build/note4
elif (( STOPWATCH )); then
  FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi,PartitionScheme=app3M_fat9M_16MB"
  DEFS+=" -DM5_STOPWATCH=1"; OUTPUT=build/stopwatch
elif (( BLE_HID )); then
  OUTPUT=build/ble-hid
fi
if (( BLE_HID )); then DEFS+=" -DHID_TRANSPORT_BLE=1"; fi
if (( BLE_HID && !BUILD_ONLY )); then
  echo "BLE HID targets require --build-only. Verify the backup and target partition before flashing." >&2
  exit 1
fi
[[ $PWD != *" "* ]] || { echo "the -include path below cannot contain spaces: $PWD"; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
FLAGS=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")

arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir "$OUTPUT" hid_bridge
(( BUILD_ONLY )) && exit 0
BEFORE=$(ports)
PORT=${PORT:-$(head -n 1 <<<"$BEFORE")}
[[ -n $PORT ]] || { echo "no board found (looked for /dev/cu.usbmodem* and /dev/ttyACM*)"; exit 1; }
stty -f "$PORT" 1200 2>/dev/null || stty -F "$PORT" 1200 2>/dev/null || true
# The ROM bootloader may come back under a new name. Follow the port that appeared after the
# reset rather than the first one listed, so other connected boards are never picked up.
new_ports() { comm -13 <(sort <<<"$BEFORE") <(ports | sort); }
for _ in $(seq 120); do sleep 0.5; [[ -n $(new_ports) ]] && break; done  # macOS took 40 s+ to list the ROM port (2026-11-26)
sleep 1  # let the ROM bootloader's serial come up
NEW=$(new_ports)
case $(grep -c . <<<"$NEW" || true) in
  0) [[ -e $PORT ]] || { echo "$PORT is gone after the reset and no new port appeared"; exit 1; } ;;
  1) PORT=$NEW ;;
  *) echo "several ports appeared after the reset, not guessing:" $NEW; exit 1 ;;
esac
arduino-cli upload -b "$FQBN" -p "$PORT" --input-dir "$OUTPUT" hid_bridge
