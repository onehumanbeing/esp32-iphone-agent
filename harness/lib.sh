# Shared by the harness scripts: the test iPhone and the app's Documents/debug.log, all over devicectl (Wi-Fi).
DEVICE=${HARNESS_IPHONE:?set HARNESS_IPHONE to the test iPhone (xcrun devicectl list devices)}
BUNDLE=${HARNESS_BUNDLE:-sh.henryht.iphoneagent}
ON=(--device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE")

# log_lines: how many lines debug.log has now (0 if there is none yet).
log_lines() {
  local f; f=$(mktemp -u /tmp/harness-log.XXXXXX)
  xcrun devicectl device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || { echo 0; return; }
  wc -l <"$f" | tr -d ' '; rm -f "$f"
}

# follow <from line> <show regex> <end regex> <seconds> [fail regex]: print new log lines matching show until one
# matches end; returns 1 when that line matches fail (or nothing came in time).
follow() {
  local from=$1 show=$2 end=$3 deadline=$((SECONDS + $4)) seen=$1 f n last
  while (( SECONDS < deadline )); do
    sleep 4
    f=$(mktemp -u /tmp/harness-log.XXXXXX)
    xcrun devicectl device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || continue
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

# launch <expect regex> <app args…>: relaunch the app with these arguments until a new log line matches expect.
# iOS sometimes brings the app back (Bluetooth restore) before devicectl's launch and the arguments are lost.
launch() {
  local expect=$1 try from f; shift
  for try in 1 2 3; do
    from=$(log_lines)
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing -- "$BUNDLE" "$@" >/dev/null
    sleep 6
    f=$(mktemp -u /tmp/harness-log.XXXXXX)
    xcrun devicectl device copy from "${ON[@]}" --source Documents/debug.log --destination "$f" >/dev/null 2>&1 || continue
    if tail -n +$((from + 1)) "$f" | grep -qE "$expect"; then rm -f "$f"; echo "$from"; return; fi
    rm -f "$f"; echo "launch $try: the app didn't take the arguments; again" >&2
  done
  echo "the app didn't take the arguments" >&2; return 1
}
