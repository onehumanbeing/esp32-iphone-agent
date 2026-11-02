#!/usr/bin/env bash
# Copy the app's debug log (and the last runs' traces with --runs) from the test iPhone to /tmp/harness-logs/<time>/.
# Never copies over an existing folder on the phone; reads only.
set -euo pipefail
DEVICE=${HARNESS_IPHONE:?set HARNESS_IPHONE}
BUNDLE=${HARNESS_BUNDLE:-sh.henryht.iphoneagent}
OUT=/tmp/harness-logs/$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/debug.log --destination "$OUT/debug.log" >/dev/null
[[ ${1:-} == --runs ]] && xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source Documents/traces --destination "$OUT/traces" >/dev/null
echo "$OUT"; tail -n "${LINES:-20}" "$OUT/debug.log"
