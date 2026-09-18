#!/bin/bash
# Builds DockPin.app. Usage:
#   ./build.sh            build into ./build
#   ./build.sh install    build, copy to /Applications and launch
#   ./build.sh release    build, sign with Developer ID, notarize and package
#                         dist/DockPin-<version>.dmg for sharing
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools first: xcode-select --install"
  exit 1
fi

APP="build/DockPin.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary so it runs on Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework ServiceManagement \
    -o "build/DockPin-$ARCH" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/DockPin" build/DockPin-arm64 build/DockPin-x86_64
rm build/DockPin-arm64 build/DockPin-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null | awk -F\" -v k="$1" '$0 ~ k {print $2; exit}'
}

if [[ "$MODE" == "release" ]]; then
  IDENTITY="${DOCKPIN_SIGN_IDENTITY:-$(find_identity 'Developer ID Application')}"
  if [[ -n "$IDENTITY" ]]; then
    # Hardened runtime and a secure timestamp are required for notarization.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  else
    echo "No 'Developer ID Application' certificate: building an unnotarized DMG."
    echo "Users will need System Settings > Privacy & Security > Open Anyway on first launch."
    codesign --force --sign - "$APP"
  fi
else
  # Sign with a real identity when available so the Accessibility grant
  # survives rebuilds. Falls back to ad hoc signing.
  IDENTITY="${DOCKPIN_SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
  codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built $APP ($VERSION)"

if [[ "$MODE" == "install" ]]; then
  pkill -x DockPin 2>/dev/null || true
  rm -rf /Applications/DockPin.app
  cp -R "$APP" /Applications/DockPin.app
  open /Applications/DockPin.app
  echo "Installed and launched /Applications/DockPin.app"
fi

if [[ "$MODE" == "release" ]]; then
  PROFILE="${DOCKPIN_NOTARY_PROFILE:-dockpin-notary}"
  DMG="dist/DockPin-$VERSION.dmg"
  STAGE="build/dmg"
  mkdir -p dist "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "DockPin" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null

  if [[ -z "$IDENTITY" ]]; then
    echo "Ready to share (unnotarized): $DMG"
    exit 0
  fi

  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  echo "Submitting $DMG for notarization (usually a few minutes)..."
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
  echo "Ready to share: $DMG"
fi
