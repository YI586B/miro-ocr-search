#!/bin/bash
# Builds a release disk image: dist/Miro-ocr-search-<version>.dmg
#
# The .app inside is ad-hoc signed — there is no Developer ID here — so macOS will refuse to open
# it on first launch until the user removes the quarantine flag. That is documented in the guide
# rather than worked around, because it cannot be worked around without a paid signing identity.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="Miro-ocr-search.app"
DMG="dist/Miro-ocr-search-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

./build-app.sh

mkdir -p dist
rm -f "$DMG"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"      # drag-to-install
hdiutil create -volname "Miro-ocr-search $VERSION" -srcfolder "$STAGE" \
               -ov -quiet -format UDZO "$DMG"

echo
echo "Built $DMG"
echo "  size      $(du -h "$DMG" | cut -f1)"
echo "  arch      $(lipo -info "$APP/Contents/MacOS/OCRSearchApp" | sed 's/.*: //')"
echo "  minimum   macOS $(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' Info.plist)"
echo "  sha256    $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
