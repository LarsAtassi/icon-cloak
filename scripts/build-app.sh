#!/bin/bash
# Builds IconCloak and wraps it in build/IconCloak.app
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/IconCloak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/IconCloak "$APP/Contents/MacOS/IconCloak"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.iconcloak.test</string>
    <key>CFBundleName</key><string>IconCloak</string>
    <key>CFBundleExecutable</key><string>IconCloak</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
