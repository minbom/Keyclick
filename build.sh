#!/bin/bash
# Builds Keyclick.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Keyclick.app"
ARCH="$(uname -m)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
	-O \
	-target "${ARCH}-apple-macos13.0" \
	-o "$APP/Contents/MacOS/Keyclick" \
	Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/*.wav "$APP/Contents/Resources/"

# The Tickeys wavs carry Finder xattrs from 2015 that codesign rejects.
xattr -cr "$APP"

# Sign with the local self-signed identity from setup-signing.sh. This makes the
# designated requirement certificate-based instead of a raw cdhash, so the
# Input Monitoring grant survives rebuilds. Falls back to ad-hoc if it is missing.
IDENTITY="Keyclick Local Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
	echo "warning: '$IDENTITY' not in keychain — run ./setup-signing.sh first." \
	     "Falling back to ad-hoc signing; Input Monitoring will need re-granting" \
	     "after every rebuild." >&2
	codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose "$APP"

echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
	pkill -x Keyclick 2>/dev/null || true
	rm -rf /Applications/Keyclick.app
	cp -R "$APP" /Applications/Keyclick.app
	echo "installed: /Applications/Keyclick.app"
fi
