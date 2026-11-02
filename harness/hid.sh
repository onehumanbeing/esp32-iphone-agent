#!/usr/bin/env bash
# Send raw board commands through the app (Debug builds: -hid), e.g. harness/hid.sh "key ctrl+space; type abc".
# The app is launched without coming to the front, so the commands land on whatever app is open on the iPhone.
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
[[ -n ${1:-} ]] || { echo 'usage: harness/hid.sh "<command>; <command>…"'; exit 1; }
FROM=$(LAUNCH_FLAGS=--no-activate launch '^[^ ]+ harness hid:' -hid "$1")
follow "$FROM" '^[^ ]+ harness hid:' '^[^ ]+ harness hid: (done|board not ready)' 60 'board not ready'
