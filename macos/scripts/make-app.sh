#!/bin/bash
# Build release binary, assemble MusicShareMVP.app, ad-hoc codesign.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)/MusicShareMVP
APP=build/MusicShareMVP.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MusicShareMVP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MusicShareMVP</string>
    <key>CFBundleIdentifier</key><string>local.viktor.MusicShareMVP</string>
    <key>CFBundleName</key><string>Music Share MVP</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Music Share discovers other Music Share devices on your local network to share playback state.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_musicshare._tcp</string>
    </array>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "OK: $APP  (launch with: open $APP)"
