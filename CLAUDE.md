# miro-ocr-library

macOS Swift package: OCR images with Apple Vision, search them with SQLite FTS5, export to Miro / files.

## Layout
- Sources/OCRSearchCore: OCR.swift (Vision OCR + findMatches boxes), Database.swift (SQLite FTS5), Miro.swift (REST v2 client, exportToMiro), Config.swift (indexFolder, dbPath)
- Sources/ocrsearch: CLI (index / search / export)
- Sources/OCRSearchApp: SwiftUI app (search window, full-size preview window with match overlay, Settings)
- miro-files/: 16 iPhone battery-usage screenshots used as test data
- run-app.command: build release + launch the app

## Build / run
    swift build -c release 2>&1 | grep -E "error|Build complete"
    .build/release/OCRSearchApp
    .build/release/ocrsearch index miro-files && .build/release/ocrsearch search "Screen Active"

## State
- Verified on the Mac: CLI index + search work on miro-files (16/16 indexed).
- Written but NOT yet compiled/tested: preview window, match overlay (box or font-colour text, on/off switch), Settings, export to file (CSV/Markdown/copy), Miro export (untested against real API; needs a Miro token).
- Index DB: ~/Library/Application Support/ocrsearch/index.db. Miro token is stored in the Keychain by the app, or MIRO_TOKEN for the CLI.

## Ideas
- Optional "cover original text" fill in text-overlay mode (sample background colour around each match)
- Multi-word queries as phrases by default
