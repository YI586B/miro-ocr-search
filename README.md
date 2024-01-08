# osx-ocr-image-search

macOS CLI that OCRs images with Apple Vision (on-device, English + Dutch) and makes them
full-text searchable through SQLite FTS5.

    swift build -c release
    .build/release/ocrsearch index ~/Pictures/Screenshots
    .build/release/ocrsearch search "invoice AND 2026"

Index lives at ~/Library/Application Support/ocrsearch/index.db. Re-running `index`
only re-OCRs new or modified files.

## Next steps
- Spotlight-style GUI (SwiftUI) with thumbnail results
- FSEvents watcher for automatic indexing
- Per-language config, PDF support

## Export to Miro
    export MIRO_TOKEN=...   # Miro access token with boards:read + boards:write
    ocrsearch export "invoice AND 2026" --name "Invoices Q3"
    ocrsearch export --files ~/Pictures/a.png ~/Pictures/b.png --board uXjVXXXXXXX=
    ocrsearch export "contract" --files ~/Desktop/extra.png --limit 10

Search hits are placed on the board as a 4-column grid: image on top, OCR snippet as a sticky
note beneath. Files passed with `--files` are added as images only. Without `--board` a new
board is created and its link printed. HEIC is not uploaded reliably; convert to PNG first.

## GUI
    swift run OCRSearchApp

Search window with thumbnails: **Index folder…**, type a query, tick results (cmd/shift-click,
or Select all), optionally **Add files…** for extra images, then **Export N to Miro…**. The token
is saved in the macOS Keychain; leave the board ID empty to create a new board. Core code
(OCR, SQLite FTS5, Miro client) lives in `Sources/OCRSearchCore`, shared by the CLI and the app.
