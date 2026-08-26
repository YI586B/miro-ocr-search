import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import OCRSearchCore

struct PreviewRequest: Codable, Hashable {
    /// Every result path from the search this preview was opened from, in list order, so the
    /// window can page through them with Previous/Next — not just the one that was clicked.
    let allPaths: [String]
    let startIndex: Int
    let query: String
    var mode: SearchMode = .phrase

    init(path: String, query: String, mode: SearchMode = .phrase, allPaths: [String]? = nil, startIndex: Int? = nil) {
        self.allPaths = allPaths ?? [path]
        self.startIndex = startIndex ?? self.allPaths.firstIndex(of: path) ?? 0
        self.query = query
        self.mode = mode
    }
}

struct PreviewView: View {
    let allPaths: [String]
    let query: String
    let searchMode: SearchMode
    /// Which of allPaths is showing. A plain @State initialized from `startIndex` (rather than
    /// `startIndex` itself driving everything directly) so Previous/Next can move it without
    /// needing a new window — the whole point of carrying the full result list through.
    @State private var index: Int
    private var path: String { allPaths.indices.contains(index) ? allPaths[index] : (allPaths.first ?? "") }

    init(allPaths: [String], startIndex: Int, query: String, searchMode: SearchMode) {
        self.allPaths = allPaths
        self.query = query
        self.searchMode = searchMode
        _index = State(initialValue: allPaths.indices.contains(startIndex) ? startIndex : 0)
    }

    @State private var image: NSImage?
    @State private var matches: [TextMatch] = []
    @State private var bgColors: [Color?] = []
    /// The original glyphs measured off the image, per match — colour and extent. See sampledInk.
    @State private var inkSamples: [InkSample?] = []
    /// The whole overlay, drawn once by the same code that draws an export (overlayLayerImage) and
    /// laid over the photo, rather than assembled from a SwiftUI view per match. Two
    /// implementations of the same drawing could not both be aligned to the ink, and keeping them
    /// in step by hand is what produced the long run of alignment bugs; this way the preview shows
    /// literally the bitmap that an export writes.
    @State private var overlayLayer: NSImage?
    @State private var matchedFonts: [String?] = []
    /// The family bestMatchingFont(forImage:) actually detected, kept separately from
    /// matchedFonts (which holds the *effective* family, i.e. `style.manualFont` when it's set) purely
    /// so the toolbar can show the user what auto-detection found, even while overridden.
    @State private var detectedFontName: String?
    @State private var pixelSize: CGSize = .zero
    /// Pixels per point for this image; see imagePointScale. Sizes shown and typed are points.
    @State private var imageScale: CGFloat = 1
    /// App-wide watermark switch; see Watermark. Held here so the preview redraws when it changes.
    @AppStorage(Watermark.key) private var watermarkOn = Watermark.defaultOn
    /// Whether the overlay is drawn, and whether it has boxes, text or both. App-wide rather than per image:
    /// these are how you are looking at whatever is open, not facts about one screenshot, and
    /// having them follow each image meant paging through results kept changing the view out from
    /// under you. The rest of the style stays per image — see OverlayStyle.
    @AppStorage(HL.show) private var overlayOn = OverlayStyle.defaults.show
    @AppStorage(HL.showBoxes) private var showBoxes = OverlayStyle.defaults.showBoxes
    @AppStorage(HL.showText) private var showText = OverlayStyle.defaults.showText
    /// Fitted font size per match, in image pixels, computed once per change of match, font or
    /// weight rather than on demand — fitting takes several font-metric lookups, and computing it
    /// inside a view body re-ran it on every mouse-move while hovering any match.
    @State private var fontSizes: [CGFloat] = []
    /// Letter spacing fitted per match, alongside the sizes and for the same reason: it depends on
    /// the font, so it is worked out again whenever the font, weight or size changes.
    @State private var trackings: [CGFloat] = []
    /// Blur fitted per match so the redrawn text is as soft as the text it covers.
    @State private var smoothness: [CGFloat] = []
    @State private var scanning = false
    @State private var failed = false
    @State private var hoverIndex: Int?
    @State private var hoverPoint: CGPoint = .zero
    /// The style panel on the right of the window. A side panel rather than a popover so the
    /// image stays in view, and clickable, while the style is being adjusted.
    @State private var showInspector = false
    /// Zoom when a pinch began, so the gesture scales from where it started.
    @State private var pinchBase: CGFloat?
    /// Whether hoverIndex was set from the keyboard (Go ▸ Next Match) rather than the mouse, in
    /// which case the hover card is placed at the match instead of at the cursor.
    @State private var keyboardMatch = false
    /// Mirrors the GeometryReader's `scale` (display points per native image pixel) outside of
    /// it, for the zoom readout and the zoom buttons, which live in .toolbar with no access to
    /// that GeometryReader.
    @State private var displayScale: CGFloat = 1
    /// On-screen points per image pixel, or nil to fit the window. Explicit rather than a
    /// multiplier of the fit scale, so a zoom level survives resizing the window and reads as a
    /// percentage the way it does in any other image viewer.
    @State private var zoom: CGFloat?
    /// Bumped by Refresh. It is part of the scan task's id, so changing it re-runs the whole
    /// scan for the same image — there is no other way to ask for that, since the task is keyed
    /// on the path and the path has not changed.
    @State private var reloadToken = 0
    /// The overlay look for the image on screen, kept per image rather than once for the app.
    /// Loaded when the image loads (its own saved settings, or the Settings window's defaults for
    /// an image that has none) and saved back on every change — see OverlayStyle.forImage.
    @State private var style = OverlayStyle()

    var body: some View {
        let box = Color(hex: style.boxHex) ?? .yellow
        let txt = Color(hex: style.textHex) ?? .black
        let bg = Color(hex: style.bgHex) ?? .white
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if let image {
                        // Fit until the user zooms, then a fixed scale inside a scroll view. The overlay
                        // layer is a single image scaled alongside the photo, so zooming costs nothing
                        // beyond the resample — nothing is re-laid-out or redrawn.
                        GeometryReader { outer in
                            let fit = pixelSize.width > 0 && pixelSize.height > 0
                                ? min(outer.size.width / pixelSize.width, outer.size.height / pixelSize.height)
                                : 1
                            let z = zoom ?? fit
                            let drawn = CGSize(width: max(pixelSize.width * z, 1), height: max(pixelSize.height * z, 1))
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image).resizable()
                                    .frame(width: drawn.width, height: drawn.height)
                                    .overlay(GeometryReader { geo in
                                        // Fitted sizes are cached at the image's native pixel scale (fontSizes);
                                        // this is the cheap per-frame conversion to on-screen points.
                                        let scale = pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1
                                        ZStack(alignment: .topLeading) {
                                            if overlayOn, let overlayLayer {
                                                Image(nsImage: overlayLayer).resizable()
                                                    .frame(width: geo.size.width, height: geo.size.height)
                                                    .allowsHitTesting(false)
                                            }
                                            // Invisible, and only for hit testing: the overlay itself is one
                                            // image now, so each match still needs its own target for the hover
                                            // card to know which one the cursor is over.
                                            //
                                            // The target is the glyphs themselves — the ink measured off the
                                            // image — not Vision's box and not the padded patch drawn over it.
                                            // Those are both bigger than the words, so the card used to appear
                                            // while the cursor was still in the margin, and on a line of
                                            // several matches the inflated areas reached into each other.
                                            ForEach(Array((overlayOn ? matches : []).enumerated()), id: \.offset) { i, m in
                                                let target = hoverTarget(i)
                                                Color.clear.contentShape(Rectangle())
                                                    .frame(width: target.width * geo.size.width,
                                                           height: target.height * geo.size.height)
                                                    .position(x: target.midX * geo.size.width,
                                                              y: (1 - target.midY) * geo.size.height)
                                                    .onContinuousHover(coordinateSpace: .named("preview")) { phase in
                                                        switch phase {
                                                        case .active(let p): hoverIndex = i; hoverPoint = p; keyboardMatch = false
                                                        case .ended: if hoverIndex == i { hoverIndex = nil }
                                                        }
                                                    }
                                            }
                                            if let i = hoverIndex, matches.indices.contains(i) {
                                                let m = matches[i]
                                                let target = hoverTarget(i)
                                                let mf = matchedFonts.indices.contains(i) ? matchedFonts[i] : nil
                                                MatchInfoPopup(text: m.text, showBoxes: showBoxes, showText: showText,
                                                               index: i + 1, total: matches.count,
                                                               boxSize: CGSize(width: target.width * pixelSize.width,
                                                                               height: target.height * pixelSize.height),
                                                               fontSize: imageFontSize(i),
                                                               design: style.design, weight: style.weight,
                                                               boxColor: box,
                                                               textColor: (style.autoTextColor ? inkSamples[safe: i] ?? nil : nil)?.color ?? txt,
                                                               bgColor: (style.autoBg ? (bgColors.indices.contains(i) ? bgColors[i] : nil) : nil) ?? bg,
                                                               opacity: style.opacity, matchedFont: mf,
                                                               fontIsManual: !style.manualFont.isEmpty)
                                                    .allowsHitTesting(false)   // never steals hover from the match it describes
                                                    .position(x: min(cardAnchor(i, in: geo.size).x + 110, geo.size.width - 100),
                                                              y: min(cardAnchor(i, in: geo.size).y + 70, geo.size.height - 60))
                                            }
                                            // Follows the overlay toggle: turning the overlay off shows the
                                            // image as it is, and a watermark left behind would contradict
                                            // that. Sized and placed in the image's own pixels and then
                                            // scaled to the window, so the preview shows the badge at the
                                            // same size relative to the image that an export writes --
                                            // see watermarkPixelSize.
                                            let ww = watermarkPixelSize.width * scale
                                            let wh = watermarkPixelSize.height * scale
                                            // Both have to agree: the menu switch decides whether the
                                            // badge exists at all, and the overlay toggle decides
                                            // whether you are looking at a marked-up image or the
                                            // plain one. Off in the menu means off regardless.
                                            if watermarkOn, overlayOn {
                                            ZStack {
                                                Rectangle().fill(watermarkBackground)
                                                if let watermarkWordmark {
                                                    Image(nsImage: watermarkWordmark).resizable().scaledToFit()
                                                        .frame(width: ww * watermarkWordmarkWidthFraction)
                                                }
                                            }
                                            .frame(width: ww, height: wh)
                                            .opacity(watermarkOpacity)
                                            .allowsHitTesting(false)
                                            .position(x: geo.size.width - watermarkRightMargin * scale - ww / 2,
                                                      y: geo.size.height - watermarkBottomMargin * scale - wh / 2)
                                            }
                                        }
                                        .coordinateSpace(name: "preview")
                                        .onAppear { setDisplayScale(scale) }
                                        .onChange(of: geo.size) { _ in setDisplayScale(pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1) }
                                        .onChange(of: pixelSize) { _ in setDisplayScale(pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1) }
                                    })
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .padding(12)
                            }
                            // Centres the image while it is smaller than the window, which is most of the
                            // time at fit scale, instead of pinning it to the top-left.
                            .frame(width: outer.size.width, height: outer.size.height)
                            .simultaneousGesture(MagnificationGesture()
                                .onChanged { v in
                                    let base = pinchBase ?? (zoom ?? displayScale)
                                    pinchBase = base
                                    zoom = min(max(base * v, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
                                }
                                .onEnded { _ in pinchBase = nil })
                            .onChange(of: fit) { f in if zoom == nil { setDisplayScale(f) } }
                        }
                    }
                    else if failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                imageInfoBar
            }
            .frame(minWidth: 400, minHeight: 400)
            if showInspector {
                Divider()
                ScrollView { inspectorPanel.padding(14) }
                    .frame(width: 320)
            }
        }
        // Standard title-bar document icon: Cmd-click it for the folder path, drag it to use the file.
        .navigationDocument(URL(fileURLWithPath: path))
        .focusedSceneValue(\.preview, previewActions)
        // ⌘= as well as ⌘+ for Zoom In, as in most Mac apps; the menu item can only show one.
        .background(Button("", action: zoomIn).keyboardShortcut("=").opacity(0).allowsHitTesting(false))
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            // Back/forward sit on the left, next to the title, as in Preview and Photos.
            ToolbarItemGroup(placement: .navigation) {
                if allPaths.count > 1 {
                    Button { goPrevious() } label: { Image(systemName: "chevron.left") }
                        .disabled(index <= 0).help("Previous image (⌘[)").accessibilityLabel("Previous image")
                    Text("\(index + 1) of \(allPaths.count)").foregroundStyle(.secondary).monospacedDigit()
                    Button { goNext() } label: { Image(systemName: "chevron.right") }
                        .disabled(index >= allPaths.count - 1).help("Next image (⌘])").accessibilityLabel("Next image")
                }
            }
            // Shortcuts for everything here are on the menu bar commands (PreviewCommands), not on
            // these buttons, so they keep working when a button is in the overflow menu.
            ToolbarItemGroup {
                Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
                    .disabled(displayScale <= Self.zoomRange.lowerBound)
                Menu {
                    Button("Actual Size (⌘0)") { zoom = 1 }
                    Button("Zoom to Fit (⌘9)") { zoom = nil }
                    Divider()
                    ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { z in
                        Button("\(Int(z * 100))%") { zoom = CGFloat(z) }
                    }
                } label: {
                    Text(zoom == nil ? "Fit" : "\(Int((displayScale * 100).rounded()))%")
                        .monospacedDigit().frame(minWidth: 40)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Zoom level")
                Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)").accessibilityLabel("Zoom in")
                    .disabled(displayScale >= Self.zoomRange.upperBound)
            }
            ToolbarItemGroup {
                // One control for the overlay: click to show or hide it, open the menu for which
                // parts are drawn.
                Menu {
                    Toggle("Show Overlay", isOn: $overlayOn)
                    Divider()
                    Toggle("Boxes", isOn: $showBoxes).disabled(!overlayOn)
                    Toggle("Text", isOn: $showText).disabled(!overlayOn)
                } label: {
                    Label("Overlay", systemImage: overlayOn ? "text.viewfinder" : "viewfinder")
                } primaryAction: {
                    overlayOn.toggle()
                }
                .help(overlayOn ? "Hide the overlay (⇧⌘O). Use the arrow for Boxes and Text."
                                : "Show the overlay (⇧⌘O). Use the arrow for Boxes and Text.")
                .accessibilityLabel("Overlay")
                Toggle(isOn: $showInspector) { Label("Style", systemImage: "paintpalette") }
                    .help("Show or hide the overlay style panel (⌥⌘I)").accessibilityLabel("Style")
                Button(action: saveImage) { Label("Export as PNG…", systemImage: "square.and.arrow.down") }
                    .help("Write this image, with its overlays and watermark, to a PNG file (⌘S)")
            }
        }
        .onExitCommand { NSApp.keyWindow?.close() }
        .task(id: "\(path)#\(reloadToken)") {
            style = OverlayStyle.forImage(path)
            image = NSImage(contentsOfFile: path)
            failed = image == nil
            bgColors = []; inkSamples = []; matchedFonts = []; fontSizes = []; trackings = []; smoothness = []
            pixelSize = .zero; detectedFontName = nil
            let terms = searchTerms(query, mode: searchMode)
            guard image != nil, !terms.isEmpty else { return }
            scanning = true
            let p = path
            matches = await Task.detached(priority: .userInitiated) {
                (try? findMatches(at: URL(fileURLWithPath: p), terms: terms)) ?? []
            }.value
            let rects = matches.map(\.rect)
            bgColors = await Task.detached(priority: .userInitiated) {
                sampledBackgroundColors(at: p, rects: rects)
            }.value
            inkSamples = await Task.detached(priority: .userInitiated) {
                sampledInk(at: p, rects: rects)
            }.value
            pixelSize = await Task.detached(priority: .userInitiated) { imagePixelSize(at: p) ?? .zero }.value
            imageScale = await Task.detached(priority: .userInitiated) { imagePointScale(at: p) }.value
            // Detected whenever text is being drawn, not only while matching is on: the font
            // menu shows "Auto (X)" as the alternative to whatever is picked, and that label is
            // only honest if X has actually been worked out.
            if showText { await detectFonts() }
            await recomputeFontSizes()
            rebuildOverlay()
            scanning = false
        }
        .onChange(of: style) { updated in
            updated.save(for: path)
            rebuildOverlay()
        }
        .onChange(of: style.autoFont) { on in
            // Always redetect on turning on, rather than only when matchedFonts is still empty:
            // a prior attempt that legitimately found no match leaves it as a *non-empty* array
            // of nils (one per match), which made the old empty-check skip ever retrying and got
            // permanently stuck showing the manual Font/Weight fallback instead.
            Task {
                if on { await detectFonts() }
                await recomputeFontSizes()
                rebuildOverlay()
            }
        }
        .onChange(of: style.design) { _ in Task { await recomputeFontSizes(); rebuildOverlay() } }
        .onChange(of: style.weight) { _ in Task { await recomputeFontSizes(); rebuildOverlay() } }
        .onChange(of: overlayOn) { _ in rebuildOverlay() }
        .onChange(of: showBoxes) { _ in rebuildOverlay() }
        .onChange(of: showText) { _ in
            Task {
                if showText, detectedFontName == nil { await detectFonts() }
                await recomputeFontSizes()
                rebuildOverlay()
            }
        }
        .onChange(of: style.kerning) { _ in recomputeTrackings(); rebuildOverlay() }
        .onChange(of: style.manualSize) { _ in recomputeTrackings(); rebuildOverlay() }
        .onChange(of: style.manualFont) { _ in
            applyFontOverride()
            Task { await recomputeFontSizes(); rebuildOverlay() }
        }
    }

    /// The style panel: text colours and font when Text is on, box look when Boxes is on, then
    /// one Reset menu and the note that all of it applies to this image only.
    private var inspectorPanel: some View {
        let box = Color(hex: style.boxHex) ?? .yellow
        let txt = Color(hex: style.textHex) ?? .black
        let bg = Color(hex: style.bgHex) ?? .white
        let boxBinding = Binding<Color>(get: { box }, set: { style.boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { style.textHex = $0.hexString })
        let bgBinding = Binding<Color>(get: { bg }, set: { style.bgHex = $0.hexString })
        return VStack(alignment: .leading, spacing: 14) {
            if showText {
                // Each "match from image" switch comes before the colour it overrides. While it
                // is on, the colour is only used where sampling fails, and says so.
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Color")
                    Toggle("Match text color from image", isOn: $style.autoTextColor)
                        .help("Pick up the text's own ink color from the image and use it for the redrawn word")
                    ColorPicker(style.autoTextColor ? "Fallback text color" : "Text color",
                                selection: txtBinding, supportsOpacity: false)
                    Toggle("Match background from image", isOn: $style.autoBg)
                        .help("Pick up the color immediately around each match and use it as its background")
                    ColorPicker(style.autoBg ? "Fallback background" : "Background",
                                selection: bgBinding, supportsOpacity: false)
                }
                Divider()
                fontSection
                Divider()
            }
            if showBoxes {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Box")
                    ColorPicker("Color", selection: boxBinding, supportsOpacity: false)
                    HStack {
                        Text("Fill opacity")
                        Slider(value: $style.opacity, in: 0...0.8)
                        Text("\(Int(style.opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Toggle("Outline", isOn: $style.outline)
                }
                Divider()
            }
            if !overlayOn || (!showText && !showBoxes) {
                Text(overlayOn ? "Boxes and Text are both off. Turn one on from the Overlay menu to style it."
                               : "The overlay is off. Turn it on from the Overlay button to style it.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            imageScopeFooter
        }
    }

    /// Says that these controls affect this image only, and holds the ways out of that: the one
    /// Reset menu (font only, this image, or a full recalculation) and making this look the default.
    private var imageScopeFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These settings apply to \((path as NSString).lastPathComponent) only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("Reset") {
                    Button("Font to Automatic") { style.resetFontToAutomatic() }
                        .disabled(!style.fontIsOverridden)
                    Button("This Image to Defaults") {
                        OverlayStyle.clear(path)
                        style = OverlayStyle.current()
                    }
                    Divider()
                    Button("Recalculate Everything (⌘R)", action: refresh).disabled(scanning)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Font to Automatic: auto font, size, spacing and smoothness, regular, no italic. This Image to Defaults: the look from Settings. Recalculate: re-read the image and match everything again.")
                Spacer()
                Button("Save as Default") { style.saveAsDefaults() }
                    .help("Use this look as the starting point for images that have no settings of their own")
            }
        }
    }

    /// The menu-bar commands' view of this window; see PreviewCommands.
    private var previewActions: PreviewActions {
        PreviewActions(
            zoomIn: zoomIn, zoomOut: zoomOut,
            actualSize: { zoom = 1 }, zoomToFit: { zoom = nil },
            canZoomIn: displayScale < Self.zoomRange.upperBound,
            canZoomOut: displayScale > Self.zoomRange.lowerBound,
            previous: goPrevious, next: goNext,
            hasPrevious: index > 0, hasNext: index < allPaths.count - 1,
            previousMatch: { stepMatch(-1) }, nextMatch: { stepMatch(1) },
            hasMatches: overlayOn && !matches.isEmpty,
            recalculate: refresh, canRecalculate: !scanning,
            export: saveImage,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            toggleInspector: { showInspector.toggle() }, inspectorShown: showInspector)
    }

    private func goPrevious() { if index > 0 { index -= 1 } }
    private func goNext() { if index < allPaths.count - 1 { index += 1 } }

    /// Selects the next or previous match from the keyboard and shows its hover card, so the card
    /// is not only reachable with the mouse.
    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let n = matches.count
        hoverIndex = ((hoverIndex ?? (delta > 0 ? -1 : 0)) + delta + n) % n
        keyboardMatch = true
    }

    /// Where the hover card for match `i` hangs from: the cursor, or the match's bottom-right
    /// corner when it was selected from the keyboard.
    private func cardAnchor(_ i: Int, in size: CGSize) -> CGPoint {
        guard keyboardMatch else { return hoverPoint }
        let t = hoverTarget(i)
        return CGPoint(x: t.maxX * size.width, y: (1 - t.minY) * size.height)
    }

    private static let zoomStep: CGFloat = 1.25
    private static let zoomRange: ClosedRange<CGFloat> = 0.02...16

    /// Re-reads the image and works every automatic setting out again, discarding the manual
    /// ones. Everything an estimate can produce — the matches, each one's colours and ink extent,
    /// the font matched to the page, the fitted sizes — comes back from the file rather than from
    /// anything remembered, which is what makes this the thing to reach for when an image has
    /// changed on disk or a previous scan went wrong.
    ///
    /// The overlay, Boxes and Text switches survive: those are how you are looking at the image,
    /// not estimates about it.
    private func refresh() {
        style.resetFontToAutomatic()
        style.autoTextColor = true; style.autoBg = true
        reloadToken += 1
    }

    private func zoomIn()   { zoom = min((zoom ?? displayScale) * Self.zoomStep, Self.zoomRange.upperBound) }
    private func zoomOut()  { zoom = max((zoom ?? displayScale) / Self.zoomStep, Self.zoomRange.lowerBound) }

    /// The image's own style, with the app-wide choices — whether the overlay is on, and
    /// boxes and text — put back on it, since the renderer takes one value describing the whole
    /// drawing rather than reaching for defaults itself.
    private var drawingStyle: OverlayStyle {
        var s = style
        s.show = overlayOn
        s.showBoxes = showBoxes
        s.showText = showText
        return s
    }

    /// Everything the shared overlay drawing needs, from what this window has already computed —
    /// no second OCR pass, and guaranteed to be the same inputs the on-screen layer was built
    /// from, so a Save writes exactly what is being looked at.
    private func currentPlan() -> RenderPlan {
        RenderPlan(pixelSize: pixelSize, imageScale: imageScale, matches: overlayOn ? matches : [],
                   bgColors: bgColors, ink: inkSamples, matchedFonts: matchedFonts,
                   fontSizes: fontSizes, trackings: trackings, smoothness: smoothness)
    }

    /// Redraws the overlay layer. Cheap relative to the scan that produced its inputs (no OCR, no
    /// pixel sampling), and it does not depend on the window's size — the layer is drawn at the
    /// image's native resolution and scaled down with the photo — so resizing never triggers it.
    private func rebuildOverlay() {
        guard pixelSize.width > 0 else { overlayLayer = nil; return }
        overlayLayer = overlayLayerImage(plan: currentPlan(), style: drawingStyle)
    }

    /// Records how big the image is being drawn, for the zoom readout. Nothing else uses it: the
    /// overlay is drawn in image pixels, so resizing or zooming never changes it and never needs
    /// it redrawn — which is the whole point of zoom being a view control.
    private func setDisplayScale(_ s: CGFloat) {
        guard s > 0, s != displayScale else { return }
        displayScale = s
    }

    /// Writes what is on screen — image, overlays, watermark — to a PNG the user picks.
    /// Hands the renderer the window's already-computed matches, sampled colours, matched font
    /// and fitted sizes instead of letting it redo the work: that is a second or more of OCR per
    /// image, and reusing them also guarantees the file is exactly what is being looked at rather
    /// than a fresh pass that could resolve a detail differently.
    private func saveImage() {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        // Captured before the panel opens, so what gets written is what was on screen when Save
        // was chosen rather than whatever the window has moved on to.
        let plan = currentPlan(), st = drawingStyle
        let (p, q, sm) = (path, query, searchMode)
        let panel = Panels.save
        panel.nameFieldStringValue = "\(name)-overlay.png"
        panel.allowedContentTypes = [.png]
        panel.message = "Saved with the overlays and watermark as shown, at the image's full resolution."
        // begin(), not runModal() -- see pick(dir:_:).
        DispatchQueue.main.async {
            panel.begin { response in
                guard response == .OK, let url = panel.url,
                      let data = renderExportPNG(path: p, query: q, searchMode: sm, style: st, plan: plan)
                else { return }
                try? data.write(to: url)
            }
        }
    }

    /// The Font section of the style panel: which family, how big, how tightly spaced, and the
    /// weight and slant. Kept apart from inspectorPanel because the combined body grew past what
    /// the type-checker would infer in reasonable time, and because this is the part of the
    /// panel with real logic in it.
    @ViewBuilder private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Laid out like an ordinary text-editing toolbar (font, point size,
            // then Bold/Italic toggles) rather than a settings-style option list.
            // Picking a font or typing a value overrides whatever auto-match/fit
            // found; "Auto" in the font menu, the Auto buttons, or Reset ▸ Font to
            // Automatic goes back to automatic.
            // The auto-fitted size this field shows while nothing is overriding
            // it. Deliberately the *first* match's size and not the hovered one:
            // the guard below decides whether a commit is a real edit by comparing
            // it against what the field was showing, and a value that moves with
            // the cursor defeats that. Hovering a smaller match redrew the field,
            // and the next commit then looked like the user had asked for the
            // previous, larger number — which is how a 15pt override got stored
            // and made every match on the page 15pt, several too large for the
            // smaller ones. Per-match sizes are still on the hover card.

            let autoSizeShown = Double(((fontSizes.first ?? 17) / imageScale).rounded())
            let sizeBinding = Binding<Double>(
                get: { style.manualSize > 0 ? style.manualSize : autoSizeShown },
                // A TextField(value:) commits whatever it is currently showing
                // every time it loses focus, whether or not the user typed
                // anything -- and while the size is automatic, what it shows is
                // the auto-fitted size. Writing that straight through silently
                // turned "auto" into a manual override pinned to one match on one
                // image, which then never adapted again: the font size looked
                // stuck, and auto-fit looked broken. So a value that matches what
                // auto is already offering is not an override; only a value the
                // user actually changed is. (This was found in the wild as a
                // stored override of exactly 17pt -- the placeholder this field
                // falls back to before anything has been fitted.)
                set: { typed in
                    let v = max(typed, 1)
                    guard style.manualSize > 0 || abs(v - autoSizeShown) >= 0.5 else { return }
                    style.manualSize = v
                }
            )
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Font")
                Toggle("Match font from image", isOn: Binding(
                    get: { style.autoFont },
                    // Turning it back on drops whatever font was picked, so the
                    // font detected from the image takes over again — which is
                    // what the toggle says it does.
                    set: { on in
                        style.autoFont = on
                        if on { style.manualFont = "" }
                    }))
                    .help("Redraw each match in whichever installed font best matches it (or \(systemFontReplacement) if that's the system font). Picking a font below turns this off.")
                Picker("", selection: Binding<String>(
                        get: { style.manualFont },
                        // Picking a specific font is the opposite of matching one
                        // from the image, so the toggle follows it; choosing
                        // "Auto" turns matching back on.
                        set: { picked in
                            style.manualFont = picked
                            style.autoFont = picked.isEmpty
                        }
                    )) {
                        Text(detectedFontName.map { "Auto (\($0))" } ?? "Auto").tag("")
                        Divider()
                        ForEach(candidateFontFamilies(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                // Size, then Bold and Italic, on one row as in a text-editing toolbar.
                HStack(spacing: 6) {
                    Text("Size").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: sizeBinding, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: sizeBinding, in: 1...400).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    // Derived from manualSize rather than stored beside it: a second
                    // flag could disagree with the number it describes, which is
                    // exactly what went wrong with the font toggle.
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualSize == 0 },
                        set: { on in style.manualSize = on ? 0 : autoSizeShown }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Size each match to the glyphs measured on the image. Typing a size turns this off.")
                    Spacer()
                    Toggle(isOn: Binding(get: { style.weight == .bold }, set: { style.weight = $0 ? .bold : .regular })) {
                        Text("B").bold()
                    }.toggleStyle(.button).help("Bold").accessibilityLabel("Bold")
                    Toggle(isOn: $style.italic) {
                        Text("I").italic()
                    }.toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
                }
                // Spacing, fitted to the width the original glyphs occupied. It is
                // what makes a substituted font track the original across a word
                // rather than drifting apart from it, so it is re-fitted whenever
                // the font changes.
                let fittedTracking = Double(((trackings.first ?? 0) / imageScale * 10).rounded() / 10)
                let trackingBinding = Binding<Double>(
                    get: { style.manualTracking ?? fittedTracking },
                    set: { typed in
                        guard style.manualTracking != nil || abs(typed - fittedTracking) >= 0.05
                        else { return }
                        style.manualTracking = typed
                    }
                )
                HStack(spacing: 8) {
                    Text("Spacing").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: trackingBinding, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: trackingBinding, in: -20...20, step: 0.1).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualTracking == nil },
                        set: { on in style.manualTracking = on ? nil : fittedTracking }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Space the letters so the redrawn word spans the same width as the original. Typing a value turns this off.")
                    Spacer()
                }
                // Softness, matched to how soft the covered text's edges are. Text drawn
                // fresh is crisper than text that has been through a screenshot's
                // resampling, and on an image that has been scaled the difference shows.
                let fittedSmoothness = Double(((smoothness.first ?? 0) / imageScale * 100).rounded() / 100)
                let smoothBinding = Binding<Double>(
                    get: { style.manualSmoothness ?? fittedSmoothness },
                    set: { typed in
                        guard style.manualSmoothness != nil || abs(typed - fittedSmoothness) >= 0.005
                        else { return }
                        style.manualSmoothness = max(typed, 0)
                    }
                )
                HStack(spacing: 8) {
                    Text("Smoothness").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: smoothBinding, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: smoothBinding, in: 0...10, step: 0.05).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualSmoothness == nil },
                        set: { on in style.manualSmoothness = on ? nil : fittedSmoothness }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Soften the redrawn text to the same degree as the text it covers. Typing a value turns this off.")
                    Spacer()
                }
                Toggle("Kerning", isOn: $style.kerning)
                    .help("Use the font's own pair kerning. Off spaces every pair evenly.")
            }
        }
    }

    /// The area a match responds to hover in: the glyphs as measured off the image, falling back
    /// to Vision's box for a match whose ink could not be isolated. Normalised, bottom-left
    /// origin, like everything else that describes where a match is.
    private func hoverTarget(_ i: Int) -> CGRect {
        (inkSamples[safe: i] ?? nil)?.rect ?? (matches.indices.contains(i) ? matches[i].rect : .zero)
    }

    /// The match count, and why nothing is drawn when the overlay or both its parts are off.
    private var matchStatus: String {
        if scanning { return "Finding matches…" }
        if searchTerms(query, mode: searchMode).isEmpty { return "" }
        let count = plural(matches.count, "match")
        if !overlayOn { return "\(count) · overlay off" }
        if !showBoxes && !showText { return "\(count) · boxes and text off" }
        return count
    }

    /// A quiet line under the image saying what it is and where it came from.
    ///
    /// Both are worth having in sight. The resolution because every size the overlay works in is
    /// in the image's own pixels, and whether a screenshot stores one or two of those per point
    /// decides what a size in points comes out as. The folder because a search spans a whole
    /// directory of near-identically named screenshots, and the title bar only carries the file
    /// name.
    private var imageInfoBar: some View {
        HStack(spacing: 8) {
            if pixelSize.width > 0 {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height))").monospacedDigit()
                if imageScale != 1 {
                    Text("@\(Int(imageScale))x")
                        .help("Stores \(Int(imageScale)) pixels per point, so a size in points is \(Int(imageScale))× that many pixels")
                }
                Text("·")
            }
            Text((path as NSString).deletingLastPathComponent)
                .truncationMode(.middle).lineLimit(1)
                .help(path)
            Spacer(minLength: 0)
            // In the info bar rather than the toolbar: it is status, not a control, and its width
            // changes while scanning, which in the toolbar shifted every item after it.
            Text(matchStatus).lineLimit(1).fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .textSelection(.enabled)
    }

    /// Small all-caps caption heading each group of controls in the style panel.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold).kerning(0.5)
            .foregroundStyle(.secondary)
    }

    /// Auto-matches the whole image's text to one closest-looking installed font at once (see
    /// bestMatchingFont(forImage:)), rather than judging each match independently — a screenshot
    /// is essentially always set in a single consistent font throughout, and scoring across many
    /// data points instead of one string at a time is what makes the system-font check reliable.
    /// Scores against *every* line on the page (allTextBoxes), not just `matches` — matches is
    /// filtered down to whatever the search happened to find, which for a specific search term
    /// can be a single short phrase, too few data points for aggregation to do any good (this
    /// was confirmed to be exactly why "New Relic" alone landed on the wrong font: with only that
    /// one string to score, it's back to the same single-string-coincidence problem aggregation
    /// was meant to fix). The overlay still only highlights `matches`, as before — this only
    /// changes what font-detection itself is scored against.
    /// Run whenever Text is on, so the font menu's "Auto (X)" label is known even while a font is
    /// picked by hand.
    private func detectFonts() async {
        guard !matches.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { return }
        let families = candidateFontFamilies()
        let px = pixelSize
        let p = path
        let winner = await Task.detached(priority: .userInitiated) {
            let all = (try? allTextBoxes(at: URL(fileURLWithPath: p))) ?? []
            let items = all.map { (text: $0.text, rect: $0.rect) }
            return bestMatchingFont(forImage: items, pixelSize: px, from: families)
        }.value
        detectedFontName = winner
        applyFontOverride()
    }

    /// The family actually rendered: `style.manualFont` when the user has picked one from the style
    /// panel's Font menu, otherwise whatever detectFonts() found. Re-run whenever either
    /// changes, without re-scanning the image (detectFonts already did the expensive part).
    private func applyFontOverride() {
        // A font the user picked wins. Otherwise the detected one, but only while "Match font
        // from image" is on — with it off and nothing picked there is no family at all, which is
        // what tells the renderer to fall back to the Font and Weight from Settings.
        let effective = !style.manualFont.isEmpty ? style.manualFont
            : (style.autoFont ? detectedFontName : nil)
        matchedFonts = Array(repeating: effective, count: matches.count)
    }

    /// A match's drawn size in points — the unit shown and typed. The renderer multiplies by the
    /// image's own pixels-per-point to get what it draws. A manual size applies to every match,
    /// as setting a size in a text editor applies to the whole selection.
    private func imageFontSize(_ i: Int) -> CGFloat {
        if style.manualSize > 0 { return style.manualSize }
        return (fontSizes.indices.contains(i) ? fontSizes[i] : 12) / imageScale
    }

    /// Fits each match's font size once, at the image's native pixel scale rather than the
    /// current window size, so it only needs recomputing when the matches, matched fonts, design
    /// or weight change — never on hover, zoom or window resize.
    private func recomputeFontSizes() async {
        guard !matches.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { fontSizes = []; return }
        let items = matches.map { (text: $0.text, rect: $0.rect) }
        let mf = matchedFonts, ink = inkSamples
        let w = style.weight, d = style.design, px = pixelSize
        fontSizes = await Task.detached(priority: .userInitiated) {
            items.enumerated().map { i, it in
                let family = i < mf.count ? mf[i] : nil
                // Fit to the glyphs measured off the image, falling back to Vision's box only
                // when they could not be isolated — see inkFittedFontSize for why the box makes
                // a poor ruler.
                if let measured = ink[safe: i] ?? nil, measured.rect.height * px.height > 1 {
                    return inkFittedFontSize(for: it.text, weight: w.font, design: d.font,
                                             matchedFamily: family,
                                             fitting: CGSize(width: measured.rect.width * px.width,
                                                             height: measured.rect.height * px.height))
                }
                let box = CGSize(width: it.rect.width * px.width, height: it.rect.height * px.height)
                return effectiveFontSize(for: it.text, weight: w.font, design: d.font,
                                         matchedFamily: family, fitting: box)
            }
        }.value
        recomputeTrackings()
        // Softness comes straight from what was measured on the image, so it needs no font.
        smoothness = inkSamples.map { smoothnessToMatch(originalRise: $0?.edgeRise ?? 0) }
    }

    /// Letter spacing per match, fitted so the drawn width matches the width the original glyphs
    /// occupied. Always follows recomputeFontSizes, since it needs the font at its final size —
    /// which is what makes the overlay re-fit itself to the image on every font change.
    private func recomputeTrackings() {
        guard !matches.isEmpty, pixelSize.width > 0 else { trackings = []; return }
        trackings = matches.enumerated().map { i, m in
            guard let measured = inkSamples[safe: i] ?? nil else { return 0 }
            let size = style.manualSize > 0 ? CGFloat(style.manualSize) * imageScale
                                            : (fontSizes[safe: i] ?? 12)
            let font = matchFont(size: size, weight: style.weight.font,
                                 design: style.design.font,
                                 matchedFamily: matchedFonts[safe: i] ?? nil)
            return inkFittedTracking(for: m.text, font: font, kerning: style.kerning,
                                     inkWidth: measured.rect.width * pixelSize.width)
        }
    }
}

/// Small card that follows the cursor while hovering a match overlay, showing what it is and
/// how it's drawn: the matched text, its font/size/colors (or box size/color), and how many
/// times that same text was found on this image.
struct MatchInfoPopup: View {
    let text: String
    let showBoxes: Bool, showText: Bool
    /// Which match this is, of how many on the image. The card describes this one instance — its
    /// own size, colours and font — so it says which instance rather than counting how many times
    /// the same word turns up.
    let index: Int
    let total: Int
    /// The size of this match's own glyphs, in the image's pixels.
    let boxSize: CGSize
    let fontSize: CGFloat
    let design: TextDesign, weight: TextWeight
    let boxColor: Color, textColor: Color, bgColor: Color
    let opacity: Double
    var matchedFont: String? = nil
    /// Whether `matchedFont` was picked by the user rather than matched from the image.
    var fontIsManual: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.headline).lineLimit(2)
            Text(total > 1 ? "Match \(index) of \(total) on this image" : "The only match on this image")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if showText {
                if let mf = matchedFont {
                    row("Font", "\(mf) \(fontIsManual ? "(picked)" : "(matched)"), \(Int(fontSize.rounded()))pt")
                } else {
                    row("Font", "\(design.label) \(weight.label), \(Int(fontSize.rounded()))pt")
                }
                colorRow("Text color", textColor)
                colorRow("Background", bgColor)
            }
            if showBoxes {
                if showText { Divider() }
                row("Box size", "\(Int(boxSize.width.rounded()))×\(Int(boxSize.height.rounded())) px")
                colorRow("Box color", boxColor)
                row("Fill strength", "\(Int(opacity * 100))%")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
        .shadow(radius: 6, y: 2)
        .frame(width: 200, alignment: .leading)
    }


    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.caption)
    }
    private func colorRow(_ label: String, _ c: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.3)))
            Text(c.hexString)
        }.font(.caption)
    }
}
