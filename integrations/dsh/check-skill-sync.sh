#!/bin/sh
# The packaged skill must match skills/manina/SKILL.md (packages can't reach files outside their folder).
set -e
here=$(dirname "$0")
diff -u "$here/../../skills/manina/SKILL.md" "$here/skills/manina/SKILL.md" && echo "manina skill in sync"
