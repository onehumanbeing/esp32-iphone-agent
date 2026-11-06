#!/usr/bin/env bash
# Pause, continue or stop the run on the test iPhone from the Mac (with harness/watch.sh: look into a step while it waits).
# Usage: harness/ctl.sh pause|continue|stop
#!/usr/bin/env bash
# Steer a running task from the Mac: pause (the run holds before its next look), continue, or stop.
# Usage: harness/ctl.sh pause|continue|stop
set -euo pipefail
cd "$(dirname "$0")/.."
source harness/lib.sh
case ${1:-} in pause|continue|stop) ;; *) echo 'usage: harness/ctl.sh pause|continue|stop'; exit 1 ;; esac
FROM=$(NO_LAUNCH=1 launch "-$1")
follow "$FROM" '^[^ ]+ (run: |debug: stop)' '^[^ ]+ (run: (paused|continued|not running)|debug: stop)' 20
