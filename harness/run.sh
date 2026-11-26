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
FROM=$(launch -run "$1")
# a run that asks for help waits for a reply nobody unattended will give: that ends it here too
follow "$FROM" '^[^ ]+ (debug: |started: |finished: |cannot start: |LLM: |step [0-9]+: help )' \
  '^[^ ]+ (finished: |cannot start: |(debug: )?run not started|debug: a run is already going|step [0-9]+: help )' "${2:-600}" \
  '(cannot start: |(debug: )?run not started|debug: a run is already going)'
