#!/usr/bin/env bash
# Build the iOS app and install it on the test iPhone over Wi-Fi (or a cable), then start it.
# Usage: harness/app.sh [--no-build] [--allow-wired]     device: $HARNESS_IPHONE (devicectl name or id)
# HARNESS_XCODE_SETTINGS: extra build settings, e.g. IA_BUNDLE_ID=... to install over the phone's only copy of the app
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/../ios"
DEVICE=${HARNESS_IPHONE:?set HARNESS_IPHONE to the test iPhone (xcrun devicectl list devices)}
BUILD=1 WIRED=0
for a in "$@"; do case $a in --no-build) BUILD=0 ;; --allow-wired) WIRED=1 ;; *) echo "unknown $a"; exit 1 ;; esac; done
transport=$(dc device info details --device "$DEVICE" 2>/dev/null | awk -F': ' '/transportType/ && !t {t=$2} END {print t}')
[[ -n $transport ]] || { echo "iPhone $DEVICE not reachable (same Wi-Fi as this Mac? unlocked?)"; exit 1; }
[[ $transport != wired || $WIRED == 1 ]] || { echo "iPhone is on the cable; unplug it or pass --allow-wired"; exit 1; }
DD=${HARNESS_DERIVED:-/tmp/harness-ios}
if (( BUILD )); then
  xcodegen >/dev/null
  xcodebuild -project IPhoneAgent.xcodeproj -scheme IPhoneAgent -configuration Debug -destination "id=$(
    dc device info details --device "$DEVICE" | awk -F': ' '/udid/ {print $2; exit}')" \
    -derivedDataPath "$DD" -allowProvisioningUpdates -quiet ${HARNESS_XCODE_SETTINGS:-} build
fi
APP=$DD/Build/Products/Debug-iphoneos/IPhoneAgent.app
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
for try in 1 2 3; do  # a wireless tunnel drops now and then
  if DC_TIMEOUT=240 dc device install app --device "$DEVICE" "$APP" >/tmp/harness-install.log 2>&1; then break; fi
  (( try == 3 )) && { tail -5 /tmp/harness-install.log; exit 1; }
  echo "install failed ($transport), retrying"; sleep 3
done
# the old build's process can outlive the install and keep the board's BLE link and the app container
# (2026-11-03: two IPhoneAgent processes after an install, every container copy hung): stop them all first
for pid in $(dc device info processes --device "$DEVICE" 2>/dev/null | awk '/IPhoneAgent\.app\/IPhoneAgent *$/ {print $1}'); do
  dc device process terminate --device "$DEVICE" --pid "$pid" --kill >/dev/null 2>&1 || true
done
dc device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
echo "installed and started $BUNDLE $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist") over $transport"
