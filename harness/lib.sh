# Shared by the harness scripts: the test iPhone and the app's Documents/debug.log, over harness/live.py when the app
# is connected to it (no devicectl), else over devicectl (Wi-Fi).
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

# live: the app is connected to harness/live.py (its log streams to $LIVE/debug.log; commands go to $LIVE/outbox/).
LIVE=${HARNESS_LIVE:-/tmp/harness-live}
live() { [[ -e $LIVE/connected && -z ${NO_LIVE:-} ]]; }

# pull_log <dest>: the app's recent log lines (live, else debug.recent.log, else debug.log for an older app).
pull_log() {
  if live; then tail -c 256000 "$LIVE/debug.log" >"$1"; return; fi
  dc device copy from "${ON[@]}" --source Documents/debug.recent.log --destination "$1" >/dev/null 2>&1 \
    || dc device copy from "${ON[@]}" --source Documents/debug.log --destination "$1" >/dev/null 2>&1
}

# log_lines: how many lines debug.log has now (0 if there is none yet).
log_lines() {
  if live; then wc -l <"$LIVE/debug.log" | tr -d ' '; return; fi
  local f; f=$(mktemp -u /tmp/harness-log.XXXXXX)
  dc device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || { echo 0; return; }
  wc -l <"$f" | tr -d ' '; rm -f "$f"
}

# follow <since> <show regex> <end regex> <seconds> [fail regex]: print new log lines (stamped after since) matching
# show until one matches end; returns 1 when that line matches fail (or nothing came in time). Reads the app's small
# debug.recent.log: the whole 2 MB debug.log over Wi-Fi, beside mirroring and a run, timed out for 11 minutes
# (2026-11-06). Lines are matched by time, not count, as that file is cut short now and then.
follow() {
  local since=$1 show=$2 end=$3 deadline=$((SECONDS + $4)) f new last
  while (( SECONDS < deadline )); do
    if live; then sleep 1; else sleep "${FOLLOW_EVERY:-5}"; fi
    f=$(mktemp -u /tmp/harness-log.XXXXXX)
    pull_log "$f" || continue
    # unstamped lines (the link's own) would end it; LC_ALL=C: `tail -c` can start mid-character (Japanese), which stopped awk
    new=$(LC_ALL=C awk -v t="$since" '$1 ~ /^[0-9]/ && $1 > t' "$f"); rm -f "$f"
    [[ -n $new ]] || continue
    since=$(tail -n 1 <<<"$new" | cut -d' ' -f1)
    LC_ALL=C grep -aE "$show" <<<"$new" || true
    if last=$(LC_ALL=C grep -aE "$end" <<<"$new" | tail -n 1) && [[ -n $last ]]; then
      [[ -z ${5:-} ]] || ! LC_ALL=C grep -aqE "$5" <<<"$last"; return
    fi
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
  local extra=()  # harness/live.py running but the app not on it yet: tell the app where it is
  if ! live && pgrep -f harness/live.py >/dev/null; then extra=(-harness-host "$(ipconfig getifaddr en0):${HARNESS_LIVE_PORT:-7290}"); fi
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@" ${extra[@]+"${extra[@]}"} >"$f"
  from=$(date -u -v-2S +%Y-%m-%dT%H:%M:%S)  # follow from here; the phone's clock may run a little behind
  if live; then mv "$f" "$LIVE/outbox/$name"; else
    dc device copy to "${ON[@]}" --source "$f" --destination "Documents/harness-inbox/$name" >/dev/null
    rm -f "$f"
  fi
  [[ -n ${NO_LAUNCH:-} ]] || dc device process launch --device "$DEVICE" "$BUNDLE" >/dev/null
  echo "$from"
}
