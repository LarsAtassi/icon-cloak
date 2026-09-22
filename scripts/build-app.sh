#!/bin/bash
# Builds IconCloak and wraps it in build/IconCloak.app.
#
#   scripts/build-app.sh              release build
#   scripts/build-app.sh --dev        adds the remote test controls (see ICONCLOAK_DEV) and build/ctl
#   scripts/build-app.sh --install    also replaces /Applications/IconCloak.app and relaunches it
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=0 INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        --install) INSTALL=1 ;;
        *) echo "unknown option: $arg"; exit 1 ;;
    esac
done

if [[ $DEV == 1 ]]; then
    swift build -c release -Xswiftc -DICONCLOAK_DEV
    swiftc -O scripts/ctl.swift -o build/ctl
else
    swift build -c release
fi

APP=build/IconCloak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/IconCloak "$APP/Contents/MacOS/IconCloak"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with scripts/make-icon.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.larsatassi.IconCloak</string>
    <key>CFBundleName</key><string>IconCloak</string>
    <key>CFBundleExecutable</key><string>IconCloak</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.4</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# A stable identity keeps macOS permissions (Accessibility) across rebuilds;
# ad-hoc signing ties them to one exact binary. Create one with scripts/create-dev-cert.sh.
IDENTITY="IconCloak Dev"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "warning: '$IDENTITY' certificate not found, signing ad-hoc (Accessibility must be re-granted after every build)"
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
    pkill -x IconCloak || true
    rm -rf /Applications/IconCloak.app
    cp -R "$APP" /Applications/
    sleep 1 # macOS needs a moment to recognize the re-signed app's permissions
    open /Applications/IconCloak.app
    echo "Installed /Applications/IconCloak.app"
fi
