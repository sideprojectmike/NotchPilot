#!/bin/bash
# Builds NotchPilot.app for Apple Silicon and Intel. Needs Apple's Command Line Tools: xcode-select --install
set -e
cd "$(dirname "$0")"
rm -rf NotchPilot.app build && mkdir -p NotchPilot.app/Contents/MacOS NotchPilot.app/Contents/Resources build
swiftc -O -target arm64-apple-macos14 main.swift -o build/NotchPilot-arm64
swiftc -O -target x86_64-apple-macos14 main.swift -o build/NotchPilot-x86_64
lipo -create build/NotchPilot-arm64 build/NotchPilot-x86_64 -output NotchPilot.app/Contents/MacOS/NotchPilot
rm -rf build
cp Info.plist NotchPilot.app/Contents/
cp AppIcon.icns NotchPilot.app/Contents/Resources/
codesign --force -s - NotchPilot.app
# Each local build has a new signature, so old permissions silently stop working. Clear them so macOS asks fresh.
tccutil reset All com.sideprojectmike.notchpilot >/dev/null 2>&1 || true
NotchPilot.app/Contents/MacOS/NotchPilot --selftest
echo "Built. Run: open NotchPilot.app"
