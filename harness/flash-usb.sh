#!/usr/bin/env bash
# Flash a board on this Mac's USB, only after its MAC matches the one asked for.
# StackChan also shows up as ESP32S3_DEV (on 2026-11-07, hid_bridge went into StackChan), so a board is never
# picked by its name or by "the only port".
# Usage: harness/flash-usb.sh MAC [flash.sh args...]
#   e.g. harness/flash-usb.sh 1c:29:04:3e:21:d8 --dual-hid --name Manina04   (keeps NVS and BLE bonds)
# Steps:
#   1. Find the running bridge's port by its USB serial (the MAC without colons).
#   2. A 1200-baud touch puts it into the ROM bootloader. The bootloader comes up as a new usbmodem port;
#      macOS can take 40 s or more to list it.
#   3. Read the MAC there with esptool and compare.
#   4. Run hardware/flash.sh on that port.
# The board keeps its own name and pairings afterwards. The iPhone app reconnects over BLE by itself.
set -euo pipefail
cd "$(dirname "$0")/.."
WANT=$(tr 'A-F' 'a-f' <<<"${1:?usage: harness/flash-usb.sh MAC [flash.sh args...]}"); shift
SERIAL=$(tr -d : <<<"$WANT" | tr 'a-f' 'A-F')
ESPTOOL=$(ls -d ~/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool | tail -1)
ports() { ls /dev/cu.usbmodem* 2>/dev/null || true; }

ROM=""
RUN=$(ports | grep "$SERIAL" || true)
if [[ -n $RUN ]]; then
  before=$(ports)
  echo "bridge on $RUN: 1200-baud touch into the ROM bootloader"
  stty -f "$RUN" 1200 || true
  for _ in $(seq 1 45); do
    sleep 2
    ROM=$(comm -13 <(echo "$before") <(ports) | grep -v "$SERIAL" | head -1 || true)
    [[ -n $ROM ]] && break
  done
else
  # Already in the bootloader (or blank): exactly one usbmodem port must be there; its MAC decides below.
  [[ $(ports | wc -l) -eq 1 ]] && ROM=$(ports)
fi
[[ -n $ROM ]] || { echo "no ROM port found for $WANT (ports: $(ports | tr '\n' ' '))"; exit 1; }

GOT=$("$ESPTOOL" --port "$ROM" --before no-reset --after no-reset read-mac 2>&1 | awk '/^MAC:/ {print tolower($2); exit}')
[[ $GOT == "$WANT" ]] || { echo "MAC on $ROM is '${GOT:-unread}', not $WANT: not flashing"; exit 2; }
echo "MAC $GOT on $ROM matches: flashing"
hardware/flash.sh "$ROM" "$@"
