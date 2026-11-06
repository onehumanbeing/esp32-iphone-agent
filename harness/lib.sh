# Shared by the harness scripts: the test iPhone and the app's Documents/debug.log, all over devicectl (Wi-Fi).
DEVICE=${HARNESS_IPHONE:?set HARNESS_IPHONE to the test iPhone (xcrun devicectl list devices)}
# the Debug build's bundle id (yours, from ios/Config/Local.xcconfig): $HARNESS_BUNDLE, else the last harness/app.sh build
BUNDLE=${HARNESS_BUNDLE:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "${HARNESS_DERIVED:-/tmp/harness-ios}/Build/Products/Debug-iphoneos/IPhoneAgent.app/Info.plist" 2>/dev/null || true)}
[[ -n $BUNDLE || $(basename "$0") == app.sh ]] || { echo "set HARNESS_BUNDLE to the app's bundle id, or run harness/app.sh first"; exit 1; }
ON=(--device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE")

# devicectl with a time cap (DC_TIMEOUT s): a copy cut off midway can wedge CoreDeviceService so that every later
# copy hangs (2026-11-03). On a timeout it restarts the service (launchd brings it back) and tries once more.
dc() {
  local rc=0
  perl -e 'alarm shift; exec @ARGV' "${DC_TIMEOUT:-45}" xcrun devicectl "$@" || rc=$?
  (( rc == 142 )) || return $rc
  echo "devicectl hung; restarting CoreDeviceService" >&2
  pkill -f CoreDeviceService || true; sleep 3
  perl -e 'alarm shift; exec @ARGV' "${DC_TIMEOUT:-45}" xcrun devicectl "$@"
}

# log_lines: how many lines debug.log has now (0 if there is none yet).
log_lines() {
  local f; f=$(mktemp -u /tmp/harness-log.XXXXXX)
  dc device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || { echo 0; return; }
  wc -l <"$f" | tr -d ' '; rm -f "$f"
}

# follow <from line> <show regex> <end regex> <seconds> [fail regex]: print new log lines matching show until one
# matches end; returns 1 when that line matches fail (or nothing came in time).
follow() {
  local from=$1 show=$2 end=$3 deadline=$((SECONDS + $4)) seen=$1 f n last
  while (( SECONDS < deadline )); do
    sleep "${FOLLOW_EVERY:-4}"  # a long run: copying the whole debug.log every 4 s over Wi-Fi hung devicectl
    f=$(mktemp -u /tmp/harness-log.XXXXXX)
    dc device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || continue
    n=$(wc -l <"$f" | tr -d ' ')
    (( n < from )) && from=0 seen=0  # the log rolled over (2 MB)
    tail -n +$((seen + 1)) "$f" | grep -E "$show" || true
    if last=$(tail -n +$((from + 1)) "$f" | grep -E "$end" | tail -n 1) && [[ -n $last ]]; then
      rm -f "$f"; [[ -z ${5:-} ]] || ! grep -qE "$5" <<<"$last"; return
    fi
    seen=$n; rm -f "$f"
  done
  echo "no result in $4 s (harness/logs.sh shows the log)"; return 1
}

# launch <app args…>: hand the app these arguments through Documents/harness-inbox/ (the Debug
# app reads it every second) and bring it up; prints the log line count from before. Launch arguments alone get
# lost: iOS often restores the app for Bluetooth first, and devicectl's launch then only brings it to the front.
launch() {
  local name f from
  name=$(date +%Y%m%d-%H%M%S)-$RANDOM.json
  f=/tmp/harness-$name
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@" >"$f"
  from=$(log_lines)
  dc device copy to "${ON[@]}" --source "$f" --destination "Documents/harness-inbox/$name" >/dev/null
  rm -f "$f"
  [[ -n ${NO_LAUNCH:-} ]] || dc device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
  echo "$from"
}
