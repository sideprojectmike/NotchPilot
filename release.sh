#!/bin/bash
# Makes dist/NotchPilot-<version>.dmg to share.
#
# Without signing, people who download it must click Open Anyway in System Settings › Privacy & Security once.
# To ship it like a real Mac app (no warnings), you need an Apple Developer account ($99/yr):
#   export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   xcrun notarytool store-credentials notchpilot --apple-id you@example.com --team-id TEAMID   # once
#   export NOTARY_PROFILE=notchpilot
set -e
cd "$(dirname "$0")"
bash build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
DMG="dist/NotchPilot-$VERSION.dmg"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --options runtime --timestamp --entitlements NotchPilot.entitlements -s "$DEVELOPER_ID" NotchPilot.app
  codesign --verify --strict NotchPilot.app
fi

rm -rf dist && mkdir -p dist/stage
cp -R NotchPilot.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -volname NotchPilot -srcfolder dist/stage -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/stage

if [ -n "$DEVELOPER_ID" ]; then
  codesign --timestamp -s "$DEVELOPER_ID" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi
echo "Ready: $DMG"
