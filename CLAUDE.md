# miro-ocr-library

User-facing docs: README.md (short), GUIDE.md (comprehensive) and docs/index.html (non-technical one-page site, GitHub Pages from main /docs) — keep GUIDE.md and docs/index.html current when behaviour, version or download link changes.

macOS Swift package: OCR images with Apple Vision, search their text, export to Miro / files.
The app searches a folder you open directly — it reads every image in it once, keeps the text in memory, and has no index or database.
The `ocrsearch` CLI is separate and still uses the SQLite FTS5 index.

## Layout
- Sources/OCRSearchCore: OCR.swift (RecognizedPage = one Vision pass giving text, match boxes and all line boxes; imagePixelSize), Search.swift (searchTerms), Database.swift (SQLite FTS5 - CLI only; also SearchMode), Miro.swift (REST v2 client, exportToMiro), Config.swift (imageExts; indexFolder, dbPath - CLI only)
- Sources/ocrsearch: CLI (index / search / export)
- Sources/OCRSearchApp (flat on purpose: Watermark.swift and FontMatch.swift find assets via #filePath):
  - OCRSearchApp.swift (entry), Commands.swift (menu bar; preview actions via focusedSceneValue), Panels.swift, Utilities.swift
  - ContentView.swift + Model.swift (search window), MiroSheet.swift, PreviewView.swift (preview window + hover card) with PreviewModel.swift (its scan and fitting) and StyleInspector.swift (style panel), SettingsView.swift
  - OverlayStyle.swift (HL keys, OverlayStyle and its per-image storage), ImageSampling.swift (sampledInk / sampledBackgroundColors / imagePointScale), FontMatch.swift (font detection and fitting), Render.swift (RenderPlan; PlanStage = the find/sample/detect/fit steps shared by export and PreviewModel; drawOverlay, renderExportPNG), Watermark.swift
  - SelfTest.swift: `OCRSearchApp --selftest <images> <out>`; Scripts/golden-check.sh baseline|check <dir> compares plans and PNG hashes, and checks the preview path (PreviewModel, fresh and restyled field by field) exports the same bytes. Run before and after any change to detection, sampling, rendering or PreviewModel. ~6 min.
- miro-files/: local test screenshots, NOT tracked (personal; purged from history before the repo was published). Scripts and notes below refer to it as it exists on this machine.
- run-app.command: build release + launch the app
- make-icons.sh + Scripts/make-icon.swift: regenerate AppIcon.iconset / AppIcon.icns / icon-1024.png from watermark.svg (build-app.sh only copies the .icns)
- Scripts/verify-watermark.swift <renderedDir> <sourceDir>: checks the watermark badge in exported images (size from the image diagonal, 20px margins, centred)

## Build / run
    swift build -c release 2>&1 | grep -E "error|Build complete"
    .build/release/OCRSearchApp
    .build/release/ocrsearch index miro-files && .build/release/ocrsearch search "Screen Active"

## State
- Verified on the Mac: CLI index + search work on miro-files. App folder search verified on miro-files: 21 images read in ~6s, search 0.001s, results only from the open folder.
- Overlay is sized and placed against the glyphs measured off the image (sampledInk -> inkFittedFontSize/inkDrawOrigin), NOT Vision's box, which runs 8-11% taller than the ink inside it. Measured on IMG_0849: placement within 1px, height within 5%, colour exact.
- Font detection (FontMatch.rankFonts) compares letter shapes: each line drawn in the candidate, stretched over the ink measured off the image, correlated with it. On the 17 iPhone screenshots in miro-files SF Pro Text ranks first on all (0.66-0.83); the old width-at-Vision-box-height score picked Verdana on all of them. Below 0.5 = no match. An SF winner is reported as Noto Sans (deliberate; bundled, registered at launch).
- The preview window and the export draw the same bitmap (drawOverlay / overlayLayerImage); MatchView now only backs the Settings sample swatch.
- Watermark size scales with the image diagonal (watermarkPixelSize(forImage:): diagonal x 63/2886.13028, height x 34/63, rounded; 63x34 at 1206x2622); margins fixed at 20px. Verified on all 21 miro-files images with Scripts/verify-watermark.swift.
- Sources/assets/logo.png and watermark.jpeg are unused: logo.png is fully opaque (its "transparency" is a painted checkerboard), so the icon and the in-app badge come from watermark.svg instead.
- Written but NOT yet compiled/tested: Miro export (untested against real API; needs a Miro token).
- Index DB (CLI only): ~/Library/Application Support/ocrsearch/index.db. Miro token is stored in the Keychain by the app, or MIRO_TOKEN for the CLI.

## Ideas
- Optional "cover original text" fill in text-overlay mode (sample background colour around each match)
- Multi-word queries as phrases by default
