#!/bin/sh
# The skill body must match skills/manina/SKILL.md; only the frontmatter differs
# (Agent Skills allows string-only metadata, so the nested openclaw block is left out here).
set -e
here=$(dirname "$0")
body() { awk 'f>=2; /^---$/{f++}' "$1"; }
body "$here/../../skills/manina/SKILL.md" > "${TMPDIR:-/tmp}/manina-skill-a.md"
body "$here/skills/manina/SKILL.md" > "${TMPDIR:-/tmp}/manina-skill-b.md"
diff -u "${TMPDIR:-/tmp}/manina-skill-a.md" "${TMPDIR:-/tmp}/manina-skill-b.md" && echo "manina skill in sync"
