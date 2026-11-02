#!/usr/bin/env bash
# Start a task in the app on the test iPhone (devicectl over Wi-Fi, -run) and print its start and end lines (steps: harness/logs.sh --runs).
# Usage: harness/run.sh "<task>" [seconds, default 600]
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
[[ -n ${1:-} ]] || { echo 'usage: harness/run.sh "<task>" [seconds]'; exit 1; }
FROM=$(launch '^[^ ]+ debug: run' -run "$1")
follow "$FROM" '^[^ ]+ (debug: |started: |finished: |cannot start: |LLM: )' \
  '^[^ ]+ (finished: |cannot start: |debug: run not started|debug: a run is already going)' "${2:-600}" \
  '(cannot start: |debug: run not started|debug: a run is already going)'
