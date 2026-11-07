#!/bin/sh
# Build the Mac CLI from the app's tree sources (no Xcode project needed): /tmp/uitree
set -eu
agent=$(cd "$(dirname "$0")/../../IPhoneAgent/Agent" && pwd)
swiftc -O -o "${1:-/tmp/uitree}" "$(dirname "$0")/main.swift" \
  "$agent/UITree.swift" "$agent/UITreeCV.swift" "$agent/UITreeOCR.swift" "$agent/JSON.swift"
