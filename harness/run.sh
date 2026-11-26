#!/usr/bin/env bash
# Stop any run still going, then start a task in the app on the test iPhone (devicectl over Wi-Fi, -run) and print its start and end lines (steps: harness/logs.sh --runs).
# Usage: harness/run.sh "<task>" [seconds, default 600]
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
[[ -n ${1:-} ]] || { echo 'usage: harness/run.sh "<task>" [seconds]'; exit 1; }
# a run left waiting (asking for help, paused) would refuse the new one ("a run is already going"): stop it first
STOP=$(NO_LAUNCH=1 launch -stop)
follow "$STOP" '^[^ ]+ (debug: stop|finished: )' '^[^ ]+ debug: stopped' 20 >/dev/null || true  # the old run has wound down
# No picture (a new app process after app.sh, a stuck session): the run would wait 5 minutes and give up. With
# the board's AirPlay name in HARNESS_BOARD, Screen Mirroring is restarted from the Mac first (tapcv.py).
if [[ -n ${HARNESS_BOARD:-} ]] && NO_LAUNCH=1 harness/hid.sh shot 2>&1 | grep -q 'err no frame'; then
  echo "no picture: restarting Screen Mirroring to $HARNESS_BOARD"
  uv run -q harness/tapcv.py mirror "$HARNESS_BOARD" --restart | tail -1 || true
fi
FROM=$(launch -run "$1")
# a run that asks for help waits for a reply nobody unattended will give: that ends it here too
follow "$FROM" '^[^ ]+ (debug: |started: |finished: |cannot start: |LLM: |step [0-9]+: help )' \
  '^[^ ]+ (finished: |cannot start: |(debug: )?run not started|debug: a run is already going|step [0-9]+: help )' "${2:-600}" \
  '(cannot start: |(debug: )?run not started|debug: a run is already going)'
