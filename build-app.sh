#!/bin/bash
# Builds the release binary and assembles it into a proper macOS .app bundle
# (Info.plist + icon), so the Dock/menu bar show "Miro-ocr-search" with a real icon
# instead of the bare "OCRSearchApp" executable name. SwiftPM alone only
# produces a Unix binary; this is the missing packaging step.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building..."
swift build -c release 2>&1 | grep -E "error|Build complete"

APP="Miro-ocr-search.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OCRSearchApp "$APP/Contents/MacOS/OCRSearchApp"
cp Info.plist "$APP/Contents/Info.plist"
cp Sources/assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
touch "$APP"

echo "Built $APP"
