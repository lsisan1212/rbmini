#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/RBMini.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ -f "Resources/RBMini.icns" ]; then
  cp "Resources/RBMini.icns" "$APP/Contents/Resources/RBMini.icns"
else
  echo "warning: Resources/RBMini.icns missing — run 'swift tools/make-icon.swift' then rebuild the icns"
fi

swiftc -O -target arm64-apple-macosx14.0 \
  Sources/RBMini/main.swift \
  -o "$APP/Contents/MacOS/rbmini" \
  -framework CoreBluetooth \
  -framework IOKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>rbmini</string>
  <key>CFBundleIdentifier</key><string>com.pman.rbmini</string>
  <key>CFBundleName</key><string>RBMini</string>
  <key>CFBundleDisplayName</key><string>RBMini</string>
  <key>CFBundleIconFile</key><string>RBMini</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>RBMini connects to the Chromecast voice remote to capture microphone audio.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>RBMini routes remote audio into a virtual microphone.</string>
</dict>
</plist>
PLIST

IDENTITY="${CODE_SIGN_IDENTITY:-SysBar Self-Signed}"
codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 \
  || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP (identity: $IDENTITY)"
