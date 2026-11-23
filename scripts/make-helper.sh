#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p dist
swiftc -O -target arm64-apple-macosx14.0 \
  Sources/RBHID/main.swift \
  -o dist/rbhid \
  -framework IOKit
codesign --force --sign "SysBar Self-Signed" dist/rbhid >/dev/null 2>&1 || true
echo "built dist/rbhid"
