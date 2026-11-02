#!/usr/bin/env bash
# Copy the app's debug log (and the last runs' traces with --runs) from the test iPhone to /tmp/harness-logs/<time>/.
# Never copies over an existing folder on the phone; reads only.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT=/tmp/harness-logs/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
dc device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/debug.log --destination "$OUT/debug.log" >/dev/null
if [[ ${1:-} == --runs ]]; then  # the latest run's steps only: a run's screenshots and video took minutes over Wi-Fi
  RUN=${2:-$(grep -oE 'run [0-9]{8}-[0-9]{6}' "$OUT/debug.log" | tail -1 | cut -d' ' -f2)}
  [[ -n $RUN ]] && dc device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "Documents/traces/$RUN/${RUN_FILE:-steps.jsonl}" \
    --destination "$OUT/traces/$RUN/${RUN_FILE:-steps.jsonl}" >/dev/null  # RUN_FILE=. for screenshots and video too
fi
echo "$OUT"; tail -n "${LINES:-20}" "$OUT/debug.log"
