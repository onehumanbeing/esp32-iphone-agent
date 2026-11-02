#!/usr/bin/env bash
# Send raw board commands through the app (Debug builds: -hid), e.g. harness/hid.sh "key ctrl+space; type abc; shot".
# "shot" saves the mirrored screen; it is copied to /tmp/harness-shots/. The app is not brought up (it reads the
# inbox in the background), so the commands land on whatever app is open on the iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
[[ -n ${1:-} ]] || { echo 'usage: harness/hid.sh "<command>; <command>…"'; exit 1; }
FROM=$(NO_LAUNCH=1 launch -hid "$1")  # not brought up: devicectl's --no-activate still brought it to the front
OUT=$(follow "$FROM" '^[^ ]+ harness hid:' '^[^ ]+ harness hid: (done|board not ready)' 60 'board not ready') || { echo "$OUT"; exit 1; }
echo "$OUT"
mkdir -p /tmp/harness-shots
for shot in $(grep -oE 'saved harness-shots/[0-9]+\.jpg' <<<"$OUT" | cut -d' ' -f2); do
  dc device copy from "${ON[@]}" --source "Documents/$shot" --destination "/tmp/$shot" >/dev/null && echo "/tmp/$shot"
done
