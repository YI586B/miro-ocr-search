#!/bin/bash
# Double-click in Finder: builds the release binary and starts the OCR search window.
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -E "error|Build complete" 
[ "${PIPESTATUS[0]}" -eq 0 ] && exec .build/release/OCRSearchApp
echo; echo "Build failed - copy the error lines above and send them to Claude."; read -n1 -p "Press any key to close"
