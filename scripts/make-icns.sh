#!/bin/zsh
# Regenerates Resources/RBMini.icns from tools/make-icon.swift
set -euo pipefail
cd "$(dirname "$0")/.."

swift tools/make-icon.swift

SET="$(mktemp -d)/RBMini.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/RBMini.icns
rm -rf "${SET:h}"
echo "wrote Resources/RBMini.icns"
