#!/bin/zsh
# Builds SurfaceHeadphonesMuteBridge, installs it into ~/Applications, and registers it to start at login.
# Every rebuild changes the code signature, so after running this, turn SurfaceHeadphonesMuteBridge off and
# on again in System Settings → Privacy & Security → Accessibility.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.surface-headphones-mute-bridge
APP="$HOME/Applications/SurfaceHeadphonesMuteBridge.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/SurfaceHeadphonesMuteBridge.log"

echo "Building..."
swiftc -O SurfaceHeadphonesMuteBridge.swift -o SurfaceHeadphonesMuteBridge

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HOME/Library/LaunchAgents"
cp SurfaceHeadphonesMuteBridge "$APP/Contents/MacOS/SurfaceHeadphonesMuteBridge"
cp SurfaceHeadphonesMuteBridge.swift "$APP/Contents/Resources/SurfaceHeadphonesMuteBridge.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>SurfaceHeadphonesMuteBridge</string>
  <key>CFBundleExecutable</key><string>SurfaceHeadphonesMuteBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Checks with Chrome whether the Meet tab is the visible tab.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/SurfaceHeadphonesMuteBridge</string>
    <string>--teams</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

echo "Installed. Check the Accessibility permission. Log: $LOG"
