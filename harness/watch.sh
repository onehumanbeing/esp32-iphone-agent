#!/usr/bin/env bash
# Follow a run step by step from the Mac: every few seconds each new step of the latest run (action, the model's
# thought, whether the screen changed, where the pointer was) and the debug.log lines that matter. Meant for a
# Monitor, so a problem is seen (and the run paused with harness/ctl.sh) while it happens, not after the run.
# Usage: harness/watch.sh [extra debug.log regex]
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
SHOW="(landing \(|pointer: |aim \(|run: |recover:|wifi silent|resumed after|started: |finished: |cannot start|LLM: |failed|calibration: ±${1:+|$1})"
seen=$(log_lines) rows=0 run="" first=1
while true; do
  sleep "${WATCH_EVERY:-4}"
  f=$(mktemp -u /tmp/harness-log.XXXXXX) s=$(mktemp -u /tmp/harness-steps.XXXXXX)
  if live; then cp "$LIVE/debug.log" "$f"; else dc device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || continue; fi
  n=$(wc -l <"$f" | tr -d ' ')
  (( n < seen )) && seen=0  # the log rolled over
  tail -n +$((seen + 1)) "$f" | grep -E "$SHOW" | grep -v 'BLE signal' | cut -c1-220 || true
  latest=$(grep -oE 'run [0-9]{8}-[0-9]{6}' "$f" | tail -1 | cut -d' ' -f2 || true)
  [[ $latest == "$run" ]] || run=$latest rows=0
  seen=$n; rm -f "$f"
  if [[ -n $run ]] && dc device copy from "${ON[@]}" --source "Documents/traces/$run/steps.jsonl" --destination "$s" \
    >/dev/null 2>&1 && out=$(python3 harness/steps.py "$s" "$rows"); then
    (( first )) || sed '$d' <<<"$out"  # a run that was going when the watch started: from its current step on
    rows=$(tail -1 <<<"$out")
  fi
  rm -f "$s"; first=0
done
