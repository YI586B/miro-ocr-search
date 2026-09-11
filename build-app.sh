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
# What the app loads at runtime (see assetURL): without these in the bundle, a copy installed on
# another Mac has no watermark wordmark, no Dock icon image and no bundled Noto Sans.
cp Sources/assets/icon-1024.png Sources/assets/watermark.svg "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/fonts"
cp Sources/assets/fonts/*.ttf "$APP/Contents/Resources/fonts/"
touch "$APP"

# Sign the assembled bundle. Without this the only signature is the one the linker put on the
# executable: its identifier is the executable's name rather than the bundle id, the Info.plist is
# not bound and no resources are sealed, so `codesign --verify` fails outright. That matters
# beyond tidiness -- AppKit's open/save panels are an out-of-process ViewBridge service that
# checks the host app's identity, and a bundle that does not verify is exactly the sort of thing
# that leaves those panels hanging in their constructor.
codesign --force --sign - --identifier com.sir.ocr-search "$APP"
codesign --verify --strict "$APP" || echo "warning: bundle still does not verify"

echo "Built $APP"
