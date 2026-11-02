#!/usr/bin/env bash
# Build the board firmware, copy it to the app on the test iPhone over Wi-Fi and have the app install it on the
# board (Debug builds: -harness-ota). Prints the app's progress and result: "harness ota: done fw … up …" or "failed …".
# Usage: harness/fw.sh [--no-build] [--crash-test] [--corrupt] [--small-gop]
#   --crash-test  an image that aborts at boot (reports 9.9.9): the board must roll back to the running one
#   --corrupt     one byte flipped after hashing: the app must refuse it and the board keep running
#   --small-gop   a 256 KB GOP buffer, so it fills (freezes) within minutes: tests resuming past a frozen GOP
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
BUILD=1 CRASH=0 CORRUPT=0 EXTRA=()
for a in "$@"; do
  case $a in --no-build) BUILD=0 ;; --crash-test) CRASH=1 ;; --corrupt) CORRUPT=1 ;; --small-gop) EXTRA+=(--small-gop) ;; *) echo "unknown $a"; exit 1 ;; esac
done
if (( BUILD )); then
  if (( CRASH )); then hardware/flash.sh --build-only --crash-test | tail -2; else hardware/flash.sh --build-only ${EXTRA[@]+"${EXTRA[@]}"} | tail -2; fi
fi
BIN=hardware/build/hid_bridge.ino.bin
DIR=harness-fw-$(date +%Y%m%d-%H%M%S)  # a new folder each time: devicectl never replaces a file it copied before
STAGE=/tmp/$DIR
mkdir -p "$STAGE"
cp "$BIN" "$STAGE/hid_bridge.ino.bin"
python3 - "$STAGE" "$CRASH" "$CORRUPT" <<'PY'
import hashlib, json, re, sys
stage, crash, corrupt = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
image = bytearray(open(f"{stage}/hid_bridge.ino.bin", "rb").read())
versions = re.findall(r'#define FW_VERSION "([^"]+)"', open("hardware/hid_bridge/version.h").read())  # crash test first
manifest = {"version": versions[0] if crash else versions[-1], "size": len(image), "sha256": hashlib.sha256(image).hexdigest(),
            "md5": hashlib.md5(image).hexdigest(), "url": "hid_bridge.ino.bin", "notes": "harness build, unsigned"}
json.dump(manifest, open(f"{stage}/firmware.json", "w"))
if corrupt:
    image[len(image) // 2] ^= 0xFF
    open(f"{stage}/hid_bridge.ino.bin", "wb").write(image)
print(f"firmware {manifest['version']} {len(image)} bytes{' (corrupted)' if corrupt else ''}")
PY
for f in hid_bridge.ino.bin firmware.json; do  # never --remove-existing-content: it wipes the whole app container
  xcrun devicectl device copy to "${ON[@]}" --source "$STAGE/$f" --destination "Documents/$DIR/$f" >/dev/null
done
rm -rf "$STAGE"
FROM=$(launch -harness-ota "$DIR")
echo "copied to Documents/$DIR; the app is installing it"
follow "$FROM" '^[^ ]+ (harness ota|firmware):' '^[^ ]+ harness ota: (done|failed)' 180 'harness ota: failed'
