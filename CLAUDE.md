# miro-ocr-library

User-facing docs: README.md (short), GUIDE.md (comprehensive) and docs/index.html (non-technical one-page site, GitHub Pages from main /docs) — keep GUIDE.md and docs/index.html current when behaviour, version or download link changes.

macOS Swift package: OCR images with Apple Vision, search their text, export to Miro / files.
The app searches a folder you open directly — it reads every image in it once, keeps the text in memory, and has no index or database.
The `ocrsearch` CLI is separate and still uses the SQLite FTS5 index.

## Layout
- Sources/OCRSearchCore: OCR.swift (RecognizedPage = one Vision pass giving text, match boxes and all line boxes; imagePixelSize), Search.swift (searchTerms), Database.swift (SQLite FTS5 - CLI only; also SearchMode), Miro.swift (REST v2 client, exportToMiro), Config.swift (imageExts; indexFolder, dbPath - CLI only)
- Sources/ocrsearch: CLI (index / search / export)
- Sources/OCRSearchApp: assets (icon-1024.png, watermark.svg, fonts/) load through assetURL (Utilities.swift) — the app bundle's Resources (build-app.sh copies them), else Sources/assets via #filePath when run from the source tree.
  - OCRSearchApp.swift (entry: Launcher picks OCRSearchApp on macOS 13+, LegacyOCRSearchApp on 12), Compatibility.swift (macOS 12 stand-ins: preview opened via the miro-ocr-search:// link, represented URL, Phrase/Any Word menu, no hover card), Commands.swift (menu bar; preview actions via focusedSceneValue), Panels.swift, Utilities.swift
  - ContentView.swift + Model.swift (search window), MiroSheet.swift, PreviewView.swift (preview window + hover card) with PreviewModel.swift (its scan and fitting) and StyleInspector.swift (style panel), SettingsView.swift
  - OverlayStyle.swift (HL keys, OverlayStyle and its per-image storage), ImageSampling.swift (sampledInk / sampledBackgroundColors / imagePointScale), FontMatch.swift (font detection and fitting), Render.swift (RenderPlan; PlanStage = the find/sample/detect/fit steps shared by export and PreviewModel; drawOverlay, renderExportPNG), Watermark.swift, ExportSize.swift (Settings ▸ Export size: every export scaled by it, default 112.4%, presets 100/112.4/124.8/150.6; renderExportPNG(scale:) draws image and overlay through the scale and the watermark at the output size; SelfTest.exportSizeHolds checks size and badge)
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
- Font detection (FontMatch.rankFonts) compares letter shapes: each line drawn in the candidate, stretched over the ink measured off the image, correlated with it. On the 17 iPhone screenshots in miro-files SF Pro Text ranks first on all (0.66-0.83); the old width-at-Vision-box-height score picked Verdana on all of them. Below 0.5 = no match. An SF winner is reported as Noto Sans (deliberate; bundled, registered at launch) and, in that stand-in case only, drawn 30% heavier via its variable weight axis (bold caps at 900) (systemFontReplacementWeightBoost; PlanStage.weightBoost; not for a hand-picked Noto Sans or a genuine Noto Sans detection).
- Sampling (ImageSampling): background = most common colour in a ring just outside the box (ringBackground), not 4 midpoints — those hit neighbouring text and inverted dark-on-light words. Ink extent counts only pixels along the background->ink colour line (skips photo texture); InkSample.isolated is false when ink fills >=97% of Vision's box, and then fitting/placing use the box and no blur. Edge softness trusted only if isolated and <= 2.5px. RecognizedPage narrows a whole-line box for a substring (URLs) by width share. Measured with --survey on ~/Downloads (43 images): poor overlays 20 -> 10, inverted 6 -> 0, blurry 30 -> 0.
- Weight (autoWeight, on by default): per match by ink coverage (matchedWeight) — not by shape score, which favours light weights. Variable fonts get an exact axis value; others regular/bold; the SF->Noto stand-in keeps its 30% boost (user directive) and only picks regular/bold. OverlayStyle decodes field by field so old saved looks still load.
- Patch (cleanedPatches, RenderPlan.patches): only the original letters are painted out — pixels towards the ink above a threshold that rises with the background's own variation, plus solid strokes joined to them up to 30% past Vision's box, widened; filled from the nearest unmasked neighbourhoods in four directions. Flat patch only when not isolated or autoBg is off. Hover card flags text under 16px as approximate.
- Per-image looks: OverlayStyle.keep(for:) saves only when the look differs from the defaults (differs(from:) ignores the app-wide switches), else clears; older versions saved a copy on every open, which froze old defaults (66 on this Mac; Settings > Forget Every Image's Own Look clears them). Style panel says when a picked font or matching-off overrides detection.
- Per-block detection (BlockFontDetector): each match's block (its line + nearby lines of similar height, same column, >= 3 lines) overrides the page's font only with a real family (not the SF stand-in) that beats the page winner on the block by blockOverrideMargin 0.05. Unrestricted per-block detection flipped single-face Mac pages between Helvetica Neue and the stand-in (median 0.768 -> 0.736); with the rule 0.769 and STRATEGIC -> Impact (+0.58).
- Edges (PlanStage.fitEdges): edge rise measured sub-pixel (edgeRise, interpolated 20%/80% crossings) on the original and on our drawing of the same word in its font/size (drawnEdgeRise(of:font:)). Softer original -> blur (quadrature); crisper -> sharpenedText steepens coverage, factor found by bisection (<= 1.6), since ~1px edges do not narrow in proportion. Dead band 0.05px. Old whole-pixel measure read ~0.25px soft (constant 1.28, now 1.05), so iPhone text (median 1.30) was never blurred. Manual Edges value: >0 blur pt, <0 sharpen (1 - v). SF->Noto stand-in (PlanStage.standsIn): edges fixed at 0, user directive, like the 30% boost.
- The preview window and the export draw the same bitmap (drawOverlay / overlayLayerImage); MatchView now only backs the Settings sample swatch.
- Watermark size scales with the image diagonal (watermarkPixelSize(forImage:): diagonal x 63/2886.13028, height x 34/63, rounded; 63x34 at 1206x2622); margins fixed at 20px. Verified on all 21 miro-files images with Scripts/verify-watermark.swift.
- Sources/assets/logo.png and watermark.jpeg are unused: logo.png is fully opaque (its "transparency" is a painted checkerboard), so the icon and the in-app badge come from watermark.svg instead.
- Deployment target macOS 12 (Package.swift, Info.plist LSMinimumSystemVersion). Built and self-tested only on macOS 15 (identical to macOS 13 build); the macOS 12 path (link-opened preview, no hover) has not been run on a real macOS 12 Mac.
- Written but NOT yet compiled/tested: Miro export (untested against real API; needs a Miro token).
- Index DB (CLI only): ~/Library/Application Support/ocrsearch/index.db. Miro token is stored in the Keychain by the app, or MIRO_TOKEN for the CLI.

## Ideas
- Optional "cover original text" fill in text-overlay mode (sample background colour around each match)
- Multi-word queries as phrases by default
