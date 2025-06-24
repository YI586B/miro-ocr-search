#!/bin/bash
# Regenerates every app-icon asset from Sources/assets/logo.png:
#   Sources/assets/AppIcon.iconset/   the ten PNG slots macOS asks for
#   Sources/assets/AppIcon.icns       what the .app bundle actually loads
#   Sources/assets/icon-1024.png      the master, and what App Store Connect wants
# Run it after changing the logo; build-app.sh only copies the .icns, it does not build it.
set -euo pipefail
cd "$(dirname "$0")"

swift Scripts/make-icon.swift
iconutil -c icns Sources/assets/AppIcon.iconset -o Sources/assets/AppIcon.icns
echo "Built Sources/assets/AppIcon.icns ($(du -h Sources/assets/AppIcon.icns | cut -f1))"
