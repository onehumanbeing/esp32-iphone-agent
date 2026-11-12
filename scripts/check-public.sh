#!/bin/sh
# Store-only sources (the App Store build's private folder, see ios/fastlane/Fastfile with_store_sources) must
# never reach this public repository. Checks a commit's tree (default HEAD); exits 1 naming what it found.
#   scripts/check-public.sh [commit]       CI and by hand
#   as .git/hooks/pre-push                 checks every commit about to be pushed
set -eu
check() {
  found=$(git ls-tree -r --name-only "$1" | grep -E '(^|/)ios/IPhoneAgent/Private/|(^|/)HandsyStore[^/]*\.swift$|(^|/)Store\.xcstrings$' || true)
  defined=$(git grep -l -E 'struct +HandsyStoreEntry' "$1" -- '*.swift' || true)
  if [ -n "$found$defined" ]; then
    echo "store-only sources in $1 (keep them out of this repository):" >&2
    printf '%s\n' "$found" "$defined" | sed '/^$/d; s/^/  /' >&2
    return 1
  fi
}
case "$(basename "$0")" in
  pre-push)
    status=0
    while read -r _ local _ _; do
      [ "$local" = 0000000000000000000000000000000000000000 ] || check "$local" || status=1
    done
    exit $status ;;
  *) check "${1:-HEAD}" && echo "no store-only sources in ${1:-HEAD}" ;;
esac
