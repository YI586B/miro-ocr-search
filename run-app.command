#!/bin/bash
# Double-click in Finder: builds the app bundle and launches it via `open`, so it
# runs as a real macOS app (proper name, icon, Dock/menu bar identity) instead of
# a bare Unix binary.
cd "$(dirname "$0")"
./build-app.sh
[ -d "Miro-ocr-search.app" ] && exec open "Miro-ocr-search.app"
echo; echo "Build failed - copy the error lines above and send them to Claude."; read -n1 -p "Press any key to close"
