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

    /// App-wide watermark switch; see Watermark. Held here so the preview redraws when it changes.
    @AppStorage(Watermark.key) private var watermarkOn = Watermark.defaultOn
    /// Whether the overlay is drawn, and whether it has boxes, text or both. App-wide rather than per image:
    /// these are how you are looking at whatever is open, not facts about one screenshot, and
    /// having them follow each image meant paging through results kept changing the view out from
    /// under you. The rest of the style stays per image — see OverlayStyle.
    @AppStorage(HL.show) private var overlayOn = OverlayStyle.defaults.show
    @AppStorage(HL.showBoxes) private var showBoxes = OverlayStyle.defaults.showBoxes
    @AppStorage(HL.showText) private var showText = OverlayStyle.defaults.showText
    /// The scan of the image on screen and everything its overlay is built from.
    @StateObject private var preview = PreviewModel()
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
                    if let image = preview.image {
                        // Fit until the user zooms, then a fixed scale inside a scroll view. The overlay
                        // layer is a single image scaled alongside the photo, so zooming costs nothing
                        // beyond the resample — nothing is re-laid-out or redrawn.
                        GeometryReader { outer in
                            let fit = preview.pixelSize.width > 0 && preview.pixelSize.height > 0
                                ? min(outer.size.width / preview.pixelSize.width, outer.size.height / preview.pixelSize.height)
                                : 1
                            let z = zoom ?? fit
                            let drawn = CGSize(width: max(preview.pixelSize.width * z, 1), height: max(preview.pixelSize.height * z, 1))
                            ScrollView([.horizontal, .vertical]) {
                                Image(nsImage: image).resizable()
                                    .frame(width: drawn.width, height: drawn.height)
                                    .overlay(GeometryReader { geo in
                                        // Fitted sizes are cached at the image's native pixel scale (fontSizes);
                                        // this is the cheap per-frame conversion to on-screen points.
                                        let scale = preview.pixelSize.width > 0 ? geo.size.width / preview.pixelSize.width : 1
                                        ZStack(alignment: .topLeading) {
                                            if overlayOn, let overlayLayer = preview.overlayLayer {
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
                                            ForEach(Array((overlayOn ? preview.matches : []).enumerated()), id: \.offset) { i, m in
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
                                            if let i = hoverIndex, preview.matches.indices.contains(i) {
                                                let m = preview.matches[i]
                                                let target = hoverTarget(i)
                                                let mf = preview.family
                                                MatchInfoPopup(text: m.text, showBoxes: showBoxes, showText: showText,
                                                               index: i + 1, total: preview.matches.count,
                                                               boxSize: CGSize(width: target.width * preview.pixelSize.width,
                                                                               height: target.height * preview.pixelSize.height),
                                                               fontSize: imageFontSize(i),
                                                               design: style.design, weight: style.weight,
                                                               boxColor: box,
                                                               textColor: (style.autoTextColor ? preview.ink[safe: i] ?? nil : nil)?.color ?? txt,
                                                               bgColor: (style.autoBg ? (preview.bgColors.indices.contains(i) ? preview.bgColors[i] : nil) : nil) ?? bg,
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
                                        .onChange(of: geo.size) { _ in setDisplayScale(preview.pixelSize.width > 0 ? geo.size.width / preview.pixelSize.width : 1) }
                                        .onChange(of: preview.pixelSize) { _ in setDisplayScale(preview.pixelSize.width > 0 ? geo.size.width / preview.pixelSize.width : 1) }
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
                    else if preview.failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                imageInfoBar
            }
            .frame(minWidth: 400, minHeight: 400)
            if showInspector {
                Divider()
                ScrollView {
                    StyleInspector(style: $style, preview: preview, path: path, overlayOn: overlayOn,
                                   showBoxes: showBoxes, showText: showText, recalculate: refresh)
                        .padding(14)
                }
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
            let saved = OverlayStyle.forImage(path)
            style = saved
            await preview.load(path: path, query: query, searchMode: searchMode, style: drawing(saved))
        }
        .onChange(of: style) { updated in
            updated.save(for: path)
            restyle()
        }
        .onChange(of: overlayOn) { _ in restyle() }
        .onChange(of: showBoxes) { _ in restyle() }
        .onChange(of: showText) { _ in restyle() }
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
            hasMatches: overlayOn && !preview.matches.isEmpty,
            recalculate: refresh, canRecalculate: !preview.scanning,
            export: saveImage,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            toggleInspector: { showInspector.toggle() }, inspectorShown: showInspector)
    }

    private func goPrevious() { if index > 0 { index -= 1 } }
    private func goNext() { if index < allPaths.count - 1 { index += 1 } }

    /// Selects the next or previous match from the keyboard and shows its hover card, so the card
    /// is not only reachable with the mouse.
    private func stepMatch(_ delta: Int) {
        guard !preview.matches.isEmpty else { return }
        let n = preview.matches.count
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
    private func drawing(_ style: OverlayStyle) -> OverlayStyle {
        var s = style
        s.show = overlayOn
        s.showBoxes = showBoxes
        s.showText = showText
        return s
    }

    /// Hands the current style to the model, which re-runs only what the change affects.
    private func restyle() {
        let st = drawing(style)
        Task { await preview.update(st) }
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
        let plan = preview.plan, st = preview.drawingStyle
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

    /// The area a match responds to hover in: the glyphs as measured off the image, falling back
    /// to Vision's box for a match whose ink could not be isolated. Normalised, bottom-left
    /// origin, like everything else that describes where a match is.
    private func hoverTarget(_ i: Int) -> CGRect {
        (preview.ink[safe: i] ?? nil)?.rect ?? (preview.matches.indices.contains(i) ? preview.matches[i].rect : .zero)
    }

    /// The match count, and why nothing is drawn when the overlay or both its parts are off.
    private var matchStatus: String {
        if preview.scanning { return "Finding matches…" }
        if searchTerms(query, mode: searchMode).isEmpty { return "" }
        let count = plural(preview.matches.count, "match")
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
            if preview.pixelSize.width > 0 {
                Text("\(Int(preview.pixelSize.width)) × \(Int(preview.pixelSize.height))").monospacedDigit()
                if preview.imageScale != 1 {
                    Text("@\(Int(preview.imageScale))x")
                        .help("Stores \(Int(preview.imageScale)) pixels per point, so a size in points is \(Int(preview.imageScale))× that many pixels")
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

    /// A match's drawn size in points — the unit shown and typed. The renderer multiplies by the
    /// image's own pixels-per-point to get what it draws. A manual size applies to every match,
    /// as setting a size in a text editor applies to the whole selection.
    private func imageFontSize(_ i: Int) -> CGFloat {
        if style.manualSize > 0 { return style.manualSize }
        return (preview.fontSizes.indices.contains(i) ? preview.fontSizes[i] : 12) / preview.imageScale
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
