# miro-ocr-library

User-facing docs: README.md (short), GUIDE.md (comprehensive) and docs/index.html (non-technical one-page site, GitHub Pages from main /docs) — keep GUIDE.md and docs/index.html current when behaviour, version or download link changes.

macOS Swift package: OCR images with Apple Vision, search their text, export to Miro / files.
The app searches a folder you open directly — it reads every image in it once, keeps the text in memory, and has no index or database.
The `ocrsearch` CLI is separate and still uses the SQLite FTS5 index.

## Layout
- Sources/OCRSearchCore: OCR.swift (Vision OCR + findMatches boxes), Database.swift (SQLite FTS5 - CLI only), Miro.swift (REST v2 client, exportToMiro), Config.swift (indexFolder, dbPath - CLI only)
- Sources/ocrsearch: CLI (index / search / export)
- Sources/OCRSearchApp: SwiftUI app (search window, full-size preview window with match overlay, Settings)
- Sources/OCRSearchApp/Render.swift: composites image + overlays + watermark at native resolution for export (OverlayStyle, RenderPlan, renderExportPNG)
- miro-files/: local test screenshots, NOT tracked (personal; purged from history before the repo was published). Scripts and notes below refer to it as it exists on this machine.
- run-app.command: build release + launch the app
- make-icons.sh + Scripts/make-icon.swift: regenerate AppIcon.iconset / AppIcon.icns / icon-1024.png from watermark.svg (build-app.sh only copies the .icns)
- Scripts/verify-watermark.swift <renderedDir> <sourceDir>: checks the watermark badge in exported images (63x34, 20px margins, centred)

## Build / run
    swift build -c release 2>&1 | grep -E "error|Build complete"
    .build/release/OCRSearchApp
    .build/release/ocrsearch index miro-files && .build/release/ocrsearch search "Screen Active"

## State
- Verified on the Mac: CLI index + search work on miro-files. App folder search verified on miro-files: 21 images read in ~6s, search 0.001s, results only from the open folder.
- Overlay is sized and placed against the glyphs measured off the image (sampledInk -> inkFittedFontSize/inkDrawOrigin), NOT Vision's box, which runs 8-11% taller than the ink inside it. Measured on IMG_0849: placement within 1px, height within 5%, colour exact.
- The preview window and the export draw the same bitmap (drawOverlay / overlayLayerImage); MatchView now only backs the Settings sample swatch.
- Watermark verified across all 17 miro-files: badge exactly 63x34 at 20px right/bottom margins, wordmark centred.
- Sources/assets/logo.png and watermark.jpeg are unused: logo.png is fully opaque (its "transparency" is a painted checkerboard), so the icon and the in-app badge come from watermark.svg instead.
- Written but NOT yet compiled/tested: Miro export (untested against real API; needs a Miro token).
- Index DB (CLI only): ~/Library/Application Support/ocrsearch/index.db. Miro token is stored in the Keychain by the app, or MIRO_TOKEN for the CLI.

## Ideas
- Optional "cover original text" fill in text-overlay mode (sample background colour around each match)
- Multi-word queries as phrases by default
