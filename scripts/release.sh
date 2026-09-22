#!/bin/bash
# Builds a release zip: build/IconCloak-<version>.zip (+ .sha256).
#
# Releases are signed with the "IconCloak Dev" certificate (scripts/create-dev-cert.sh).
# Always sign releases with the SAME certificate: macOS ties the Accessibility permission to
# it, so users keep their permission across updates. Back it up (Keychain Access → export).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
APP=build/IconCloak.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Safety checks: no dev controls, signed with the release certificate.
# (Output is captured first: with pipefail, `grep -q` closing the pipe early fails the check.)
BINARY_STRINGS=$(strings "$APP/Contents/MacOS/IconCloak")
SIGNATURE=$(codesign -dv --verbose=2 "$APP" 2>&1)
if grep -q "dev.iconcloak.cmd" <<< "$BINARY_STRINGS"; then
    echo "error: build contains dev controls"; exit 1
fi
if ! grep -q "Authority=IconCloak Dev" <<< "$SIGNATURE"; then
    echo "error: not signed with 'IconCloak Dev' (run scripts/create-dev-cert.sh)"; exit 1
fi
codesign --verify --strict "$APP"

ZIP="build/IconCloak-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Release: $ZIP"
cat "$ZIP.sha256"
