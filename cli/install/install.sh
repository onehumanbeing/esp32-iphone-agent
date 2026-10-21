#!/bin/sh
# Installs esp32agent from the release list (https://handsy.tech/cli/versions.json), else from GitHub Releases:
#   curl -fsSL https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.sh | sh
# Env: ESP32AGENT_VERSION=0.1.0 (default: latest), ESP32AGENT_BIN_DIR (default ~/.local/bin),
#      ESP32AGENT_VERSIONS_URL (default https://handsy.tech/cli/versions.json),
#      ESP32AGENT_ARCHIVE=/path/esp32agent_<os>_<arch>.tar.gz to install a local build (checksums.txt next to it,
#      or ESP32AGENT_CHECKSUMS=/path), ESP32AGENT_FFMPEG=yes|no to answer the ffmpeg question without a prompt.
set -eu

REPO=onehumanbeing/esp32-iphone-agent
VERSIONS_URL=${ESP32AGENT_VERSIONS_URL:-https://handsy.tech/cli/versions.json}
BIN_DIR=${ESP32AGENT_BIN_DIR:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
die() { printf 'esp32agent install: %s\n' "$*" >&2; exit 1; }

case $(uname -s) in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS $(uname -s) (on Windows use install.ps1)" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac
name=esp32agent_${os}_${arch}.tar.gz

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ -n "${ESP32AGENT_ARCHIVE:-}" ]; then
  [ -f "$ESP32AGENT_ARCHIVE" ] || die "no file $ESP32AGENT_ARCHIVE"
  cp "$ESP32AGENT_ARCHIVE" "$tmp/$name"
  sums=${ESP32AGENT_CHECKSUMS:-$(dirname "$ESP32AGENT_ARCHIVE")/checksums.txt}
  [ -f "$sums" ] || die "no checksums file $sums"
  cp "$sums" "$tmp/checksums.txt"
  say "installing esp32agent from $ESP32AGENT_ARCHIVE"
else
  version=${ESP32AGENT_VERSION:-}
  # versions.json: {"latest":"X","versions":[{"version":"X","assets":{"<os>_<arch>":{"url":"…","sha256":"…"}}}]}
  # (each "version" before its "assets", as the release workflow writes it)
  flat=$(curl -fsSL "$VERSIONS_URL" 2>/dev/null | tr -d ' \t\r\n') || flat=""
  if [ -n "$flat" ]; then
    [ -n "$version" ] || version=$(printf '%s' "$flat" | sed -n 's/.*"latest":"\([^"]*\)".*/\1/p')
    rel=${flat#*\"version\":\"$version\"}
    if [ -n "$version" ] && [ "$rel" != "$flat" ]; then
      rel=${rel%%\"version\":*}
      asset=${rel#*\"${os}_${arch}\":\{}
      asset=${asset%%\}*}
      if [ "$asset" != "$rel" ]; then
        aurl=$(printf '%s' "$asset" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
        asha=$(printf '%s' "$asset" | sed -n 's/.*"sha256":"\([0-9a-fA-F]*\)".*/\1/p')
      fi
    fi
  fi
  if [ -n "${aurl:-}" ] && [ -n "${asha:-}" ]; then
    say "downloading esp32agent $version ($os/$arch)"
    curl -fsSL -o "$tmp/$name" "$aurl" || die "download failed: $aurl"
    printf '%s  %s\n' "$asha" "$name" >"$tmp/checksums.txt"
  else
    [ -n "$flat" ] && say "no $os/$arch build of ${version:-the latest version} in $VERSIONS_URL; trying GitHub Releases"
    if [ -z "$version" ]; then
      version=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=50" |
        sed -n 's/.*"tag_name": *"cli-v\([^"]*\)".*/\1/p' | head -n 1)
      [ -n "$version" ] || die "no cli-v* release found on github.com/$REPO"
    fi
    url=https://github.com/$REPO/releases/download/cli-v$version
    say "downloading esp32agent $version ($os/$arch)"
    curl -fsSL -o "$tmp/$name" "$url/$name" || die "download failed: $url/$name"
    curl -fsSL -o "$tmp/checksums.txt" "$url/checksums.txt" || die "download failed: $url/checksums.txt"
  fi
fi

want=$(awk -v n="$name" '$2 == n || $2 == "*"n { print $1 }' "$tmp/checksums.txt")
[ -n "$want" ] || die "$name is not listed in checksums.txt"
got=$(sha256 "$tmp/$name")
[ "$want" = "$got" ] || die "checksum mismatch for $name (expected $want, got $got)"

tar -xzf "$tmp/$name" -C "$tmp" esp32agent || die "bad archive $name"
mkdir -p "$BIN_DIR"
install -m 755 "$tmp/esp32agent" "$BIN_DIR/esp32agent"
say "installed $BIN_DIR/esp32agent ($("$BIN_DIR/esp32agent" version))"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "warning: $BIN_DIR is not on your PATH; add it, e.g.: echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile" ;;
esac

# ffmpeg decodes the mirrored screen (screenshots need it).
if ! command -v ffmpeg >/dev/null 2>&1; then
  installer=""
  if command -v brew >/dev/null 2>&1; then installer="brew install ffmpeg"
  elif command -v apt-get >/dev/null 2>&1; then installer="sudo apt-get install -y ffmpeg"
  elif command -v dnf >/dev/null 2>&1; then installer="sudo dnf install -y ffmpeg"
  fi
  answer=${ESP32AGENT_FFMPEG:-}
  if [ -n "$installer" ] && [ -z "$answer" ] && [ -r /dev/tty ]; then
    printf 'ffmpeg is needed for screenshots. Run "%s" now? [y/N] ' "$installer"
    read -r answer </dev/tty || answer=n
  fi
  case $answer in
    y | Y | yes) [ -n "$installer" ] && sh -c "$installer" ;;
    *) say "ffmpeg not found: install it for screenshots (${installer:-see https://ffmpeg.org/download.html})" ;;
  esac
fi

cat <<EOF

Next:
  1. Plug the board into the iPhone, then within 3 minutes:  esp32agent pair
  2. On the iPhone: Control Center > Screen Mirroring > ESP32 Agent
  3. Let your agent use it:
       claude mcp add esp32agent -- esp32agent mcp
       codex mcp add esp32agent -- esp32agent mcp
       esp32agent skill install      (Claude Code skill)
EOF
