#!/bin/zsh
# Installs the RBHID root helper as a LaunchDaemon. Requires sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "run with: sudo zsh scripts/install-helper.sh"
  exit 1
fi

BIN="/Library/Application Support/RBMini/rbhid"
PLIST="/Library/LaunchDaemons/com.pman.rbhid.plist"

mkdir -p "/Library/Application Support/RBMini"
cp "dist/rbhid" "$BIN"
chown root:wheel "$BIN"
chmod 755 "$BIN"

cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.pman.rbhid</string>
  <key>ProgramArguments</key>
  <array><string>/Library/Application Support/RBMini/rbhid</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/rbhid.err</string>
  <key>StandardOutPath</key><string>/var/log/rbhid.out</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system/com.pman.rbhid 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "installed. log: /var/log/rbhid.log"
