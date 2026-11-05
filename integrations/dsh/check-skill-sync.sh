#!/bin/sh
# The packaged skill must match skills/handsy/SKILL.md (packages can't reach files outside their folder).
set -e
here=$(dirname "$0")
diff -u "$here/../../skills/handsy/SKILL.md" "$here/skills/handsy/SKILL.md" && echo "handsy skill in sync"
