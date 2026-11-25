#!/usr/bin/env bash
# Stop any run still going, then start a task in the app on the test iPhone (devicectl over Wi-Fi, -run) and print its start and end lines (steps: harness/logs.sh --runs).
# Usage: harness/run.sh "<task>" [seconds, default 600]
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
[[ -n ${1:-} ]] || { echo 'usage: harness/run.sh "<task>" [seconds]'; exit 1; }
# a run left waiting (asking for help, paused) would refuse the new one ("a run is already going"): stop it first
STOP=$(NO_LAUNCH=1 launch -stop)
follow "$STOP" '^[^ ]+ (debug: stop|finished: )' '^[^ ]+ debug: stop' 15 >/dev/null || true
sleep 2  # the stop is asynchronous: let a running task wind down before the new one asks
FROM=$(launch -run "$1")
follow "$FROM" '^[^ ]+ (debug: |started: |finished: |cannot start: |LLM: )' \
  '^[^ ]+ (finished: |cannot start: |debug: run not started|debug: a run is already going)' "${2:-600}" \
  '(cannot start: |debug: run not started|debug: a run is already going)'
