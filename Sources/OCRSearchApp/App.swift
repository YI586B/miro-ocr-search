import SwiftUI
import AppKit
import ImageIO
import OCRSearchCore

/// Sources/assets/logo.png, resolved relative to this source file's own location (not the
/// process's current working directory) so it's found the same way regardless of how the app
/// was launched.
let appLogo: NSImage? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // App.swift -> Sources/OCRSearchApp/
        .deletingLastPathComponent()   // -> Sources/
        .appendingPathComponent("assets/logo.png")
    return NSImage(contentsOfFile: url.path)
}()

/// Small rounded Miro logo badge, marking the app's Miro-related actions (export button, the
/// export sheet, "open board"). Square, dark card with the wordmark baked in — looks right at
/// any size without needing its own background.
struct MiroBadge: View {
    var size: CGFloat = 16
    var body: some View {
        Group {
            if let appLogo {
                Image(nsImage: appLogo).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
        .frame(width: size, height: size)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)      // needed when launched via `swift run`
        NSApp.activate(ignoringOtherApps: true)
        registerBundledFonts()
        if let appLogo { NSApp.applicationIconImage = appLogo }   // Dock icon while running
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct OCRSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("OCR Image Search") { ContentView().frame(minWidth: 760, minHeight: 520) }
        // Full-size viewer: one window per image, closable with the red button, Cmd+W or Esc.
        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $req in
            if let req { PreviewView(path: req.path, query: req.query, searchMode: req.mode) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}

struct PreviewRequest: Codable, Hashable {
    let path: String
    let query: String
    var mode: SearchMode = .phrase
}

/// An image's pixel dimensions, read from its metadata without decoding the full bitmap.
func imagePixelSize(at path: String) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
    return CGSize(width: w, height: h)
}

/// Approximate the image's background color immediately around each match box, so text-overlay
/// mode can paint the redrawn word over a same-colored patch instead of just floating on top of
/// the original characters. Samples just outside the box on all four sides — at the midpoint of
/// each edge, offset outward by a small margin so it lands past any anti-aliased glyph pixel,
/// never inside the box itself — and averages them; falls back to `nil` (caller uses its own
/// default) if the image can't be read as a bitmap.
///
/// Deliberately does NOT call `.usingColorSpace(.sRGB)` on the sampled NSColor: colorAt(x:y:)
/// returns components already tagged NSCalibratedRGBColorSpace that numerically match the raw
/// stored sRGB bytes (verified directly against the PNG's own pixel data), but converting that
/// tag to `.sRGB` applies a real, incorrect gamma remap on top of already-correct numbers —
/// measured shifting (28,28,28)/`#1C1C1C` to (37,37,37)/`#252525`. Using the components as
/// returned, unconverted, matches the source image exactly.
func sampledBackgroundColors(at path: String, rects: [CGRect]) -> [Color?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return Array(repeating: nil, count: rects.count) }
    func sample(_ rect: CGRect) -> Color? {
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        let midX = (x0 + x1) / 2, midY = (yTop + yBottom) / 2
        let marginX = max((x1 - x0) * 0.15, 2 / CGFloat(w)), marginY = max((yBottom - yTop) * 0.15, 2 / CGFloat(h))
        let points: [(CGFloat, CGFloat)] = [
            (midX, yTop - marginY), (midX, yBottom + marginY),   // just above, just below
            (x0 - marginX, midY), (x1 + marginX, midY)           // just left, just right
        ]
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for (nx, ny) in points {
            let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
            let py = min(max(Int(ny * CGFloat(h)), 0), h - 1)
            guard let c = rep.colorAt(x: px, y: py) else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
        guard n > 0 else { return nil }
        return Color(.sRGB, red: r / n, green: g / n, blue: b / n, opacity: 1)
    }
    return rects.map(sample)
}

/// Approximate the color of the text itself within each match box, for text-overlay mode to draw
/// the redrawn word in — rather than always using the manually picked Font color. Samples a grid
/// of points inside the box, first finding the box's background reference the same way
/// sampledBackgroundColors does (its edge midpoints, just outside the box), then averaging
/// whichever interior samples differ *most* from that background — those are the ones most
/// likely to have landed on actual glyph ink rather than background showing through between or
/// around the letters. Falls back to `nil` if the image can't be read as a bitmap, or nothing
/// inside the box stands out from its background at all (e.g. blank space).
func sampledTextColors(at path: String, rects: [CGRect]) -> [Color?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return Array(repeating: nil, count: rects.count) }
    func colorAt(_ nx: CGFloat, _ ny: CGFloat) -> NSColor? {
        let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
        let py = min(max(Int(ny * CGFloat(h)), 0), h - 1)
        return rep.colorAt(x: px, y: py)
    }
    func sample(_ rect: CGRect) -> Color? {
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        let midX = (x0 + x1) / 2, midY = (yTop + yBottom) / 2
        let marginX = max((x1 - x0) * 0.15, 2 / CGFloat(w)), marginY = max((yBottom - yTop) * 0.15, 2 / CGFloat(h))
        let bg = [colorAt(midX, yTop - marginY), colorAt(midX, yBottom + marginY),
                  colorAt(x0 - marginX, midY), colorAt(x1 + marginX, midY)].compactMap { $0 }
        guard !bg.isEmpty else { return nil }
        let bgR = bg.map(\.redComponent).reduce(0, +) / CGFloat(bg.count)
        let bgG = bg.map(\.greenComponent).reduce(0, +) / CGFloat(bg.count)
        let bgB = bg.map(\.blueComponent).reduce(0, +) / CGFloat(bg.count)

        var candidates: [(color: NSColor, distance: CGFloat)] = []
        let steps = 7
        for iy in 1..<steps {
            for ix in 1..<steps {
                let nx = x0 + (x1 - x0) * CGFloat(ix) / CGFloat(steps)
                let ny = yTop + (yBottom - yTop) * CGFloat(iy) / CGFloat(steps)
                guard let c = colorAt(nx, ny) else { continue }
                let d = (c.redComponent - bgR) * (c.redComponent - bgR)
                    + (c.greenComponent - bgG) * (c.greenComponent - bgG)
                    + (c.blueComponent - bgB) * (c.blueComponent - bgB)
                candidates.append((c, d))
            }
        }
        candidates.sort { $0.distance > $1.distance }
        let ink = candidates.prefix(max(1, candidates.count / 4))   // top quartile: likely glyph pixels
        guard let top = ink.first, top.distance > 0.001 else { return nil }   // nothing stood out
        let r = ink.map { $0.color.redComponent }.reduce(0, +) / CGFloat(ink.count)
        let g = ink.map { $0.color.greenComponent }.reduce(0, +) / CGFloat(ink.count)
        let b = ink.map { $0.color.blueComponent }.reduce(0, +) / CGFloat(ink.count)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
    return rects.map(sample)
}

/// Query -> the term(s) to look for on the image (drops quotes, operators, wildcards). In
/// `.phrase` mode the whole query is kept together as one term, so only that contiguous phrase
/// gets highlighted; in `.words` mode each word is highlighted separately, wherever it appears.
func searchTerms(_ q: String, mode: SearchMode) -> [String] {
    if mode == .phrase {
        let t = q.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"()*^+-"))
        return t.isEmpty ? [] : [t]
    }
    let skip: Set<String> = ["AND", "OR", "NOT", "NEAR"]
    return q.components(separatedBy: CharacterSet(charactersIn: " \t\n\"()"))
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*^+-")) }
        .filter { !$0.isEmpty && !skip.contains($0) }
}

/// NSImage is not Sendable; the image is created once on a background task and only read afterwards.
struct ImageBox: @unchecked Sendable {
    let image: NSImage?
    init(_ i: NSImage?) { image = i }
}

struct Thumb: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.quaternary) }
        }
        .frame(width: 72, height: 72)
        .task(id: path) {
            let p = path
            image = await Task.detached(priority: .utility) { () -> ImageBox in
                guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return ImageBox(nil) }
                let o: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceThumbnailMaxPixelSize: 160,
                                          kCGImageSourceCreateThumbnailWithTransform: true]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, o as CFDictionary) else { return ImageBox(nil) }
                return ImageBox(NSImage(cgImage: cg, size: .zero))
            }.value.image
        }
    }
}

struct PreviewView: View {
    let path: String
    let query: String
    let searchMode: SearchMode
    @State private var image: NSImage?
    @State private var matches: [TextMatch] = []
    @State private var bgColors: [Color?] = []
    @State private var textColors: [Color?] = []
    @State private var matchedFonts: [String?] = []
    /// The family bestMatchingFont(forImage:) actually detected, kept separately from
    /// matchedFonts (which holds the *effective* family, i.e. `manualFont` when it's set) purely
    /// so the toolbar can show the user what auto-detection found, even while overridden.
    @State private var detectedFontName: String?
    @State private var pixelSize: CGSize = .zero
    /// Fitted font size per match, computed once at the image's native pixel scale rather than
    /// on demand — fitting takes several font-metric lookups, and computing it live inside
    /// MatchView/MatchInfoPopup's body meant it re-ran on every mouse-move while hovering *any*
    /// match, for *every* visible match, which was especially slow with auto-font on (family
    /// lookups, not just system-font construction). Scaled to the actual on-screen size at
    /// render time (a cheap multiply) via displayFontSize(_:in:).
    @State private var fontSizes: [CGFloat] = []
    /// Exact renderable name (PostScript name) for each match's matchedFont, resolved once
    /// instead of on every render — see renderableFontName.
    @State private var renderedFontNames: [String?] = []
    @State private var scanning = false
    @State private var failed = false
    @State private var hoverIndex: Int?
    @State private var hoverPoint: CGPoint = .zero
    @State private var showStylePopover = false
    @AppStorage(HL.show) private var show = true
    @AppStorage(HL.mode) private var mode = "box"
    @AppStorage(HL.boxHex) private var boxHex = HL.defaultBox
    @AppStorage(HL.opacity) private var opacity = 0.35
    @AppStorage(HL.outline) private var outline = true
    @AppStorage(HL.textHex) private var textHex = HL.defaultText
    @AppStorage(HL.autoTextColor) private var autoTextColor = true
    @AppStorage(HL.bgHex) private var bgHex = HL.defaultBg
    @AppStorage(HL.autoBg) private var autoBg = true
    @AppStorage(HL.design) private var design = "default"
    @AppStorage(HL.weight) private var weight = "regular"
    @AppStorage(HL.autoFont) private var autoFont = false
    @AppStorage(HL.manualFont) private var manualFont = ""
    @AppStorage(HL.sizeScale) private var sizeScale: Double = 1.0

    var body: some View {
        let box = Color(hex: boxHex) ?? .yellow
        let txt = Color(hex: textHex) ?? .black
        let bg = Color(hex: bgHex) ?? .white
        let boxBinding = Binding<Color>(get: { box }, set: { boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { textHex = $0.hexString })
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .overlay(GeometryReader { geo in
                        // Fitted sizes are cached at the image's native pixel scale (fontSizes);
                        // this is the cheap per-frame conversion to on-screen points.
                        let scale = pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1
                        ZStack(alignment: .topLeading) {
                            ForEach(Array((show ? matches : []).enumerated()), id: \.offset) { i, m in
                                let w = m.rect.width * geo.size.width + matchBoxPadding
                                let h = m.rect.height * geo.size.height + matchBoxPadding
                                MatchView(text: m.text, size: CGSize(width: w, height: h), mode: mode,
                                          box: box, textColor: txt, opacity: opacity, outline: outline,
                                          design: design, weight: weight,
                                          sampled: bgColors.indices.contains(i) ? bgColors[i] : nil, background: bg,
                                          autoBackground: autoBg,
                                          matchedFont: matchedFonts.indices.contains(i) ? matchedFonts[i] : nil,
                                          autoFont: autoFont,
                                          fontSize: displayFontSize(i, scale: scale),
                                          renderedFontName: renderedFontNames.indices.contains(i) ? renderedFontNames[i] : nil,
                                          sampledTextColor: textColors.indices.contains(i) ? textColors[i] : nil,
                                          autoTextColor: autoTextColor)
                                    .position(x: m.rect.midX * geo.size.width,
                                              y: (1 - m.rect.midY) * geo.size.height)
                                    .onContinuousHover(coordinateSpace: .named("preview")) { phase in
                                        switch phase {
                                        case .active(let p): hoverIndex = i; hoverPoint = p
                                        case .ended: if hoverIndex == i { hoverIndex = nil }
                                        }
                                    }
                            }
                            if let i = hoverIndex, matches.indices.contains(i) {
                                let m = matches[i]
                                let w = m.rect.width * geo.size.width + matchBoxPadding
                                let h = m.rect.height * geo.size.height + matchBoxPadding
                                let mf = matchedFonts.indices.contains(i) ? matchedFonts[i] : nil
                                MatchInfoPopup(text: m.text, mode: mode,
                                               count: matches.filter { $0.text.caseInsensitiveCompare(m.text) == .orderedSame }.count,
                                               boxSize: CGSize(width: w, height: h),
                                               fontSize: displayFontSize(i, scale: scale),
                                               design: design, weight: weight,
                                               boxColor: box,
                                               textColor: (autoTextColor ? (textColors.indices.contains(i) ? textColors[i] : nil) : nil) ?? txt,
                                               bgColor: (autoBg ? (bgColors.indices.contains(i) ? bgColors[i] : nil) : nil) ?? bg,
                                               opacity: opacity, matchedFont: mf, autoFont: autoFont,
                                               fontIsManual: !manualFont.isEmpty)
                                    .allowsHitTesting(false)   // never steals hover from the match it describes
                                    .position(x: min(hoverPoint.x + 110, geo.size.width - 100),
                                              y: min(hoverPoint.y + 70, geo.size.height - 60))
                            }
                        }
                        .coordinateSpace(name: "preview")
                    })
                    .padding(12)
            }
            else if failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(minWidth: 400, minHeight: 400)
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            Text(scanning ? "Finding matches…" : (searchTerms(query, mode: searchMode).isEmpty ? "" : (show ? "\(matches.count) match(es)" : "overlay off")))
                .foregroundStyle(.secondary)
            Toggle("Overlay", isOn: $show)
                .toggleStyle(.switch).help("Show or hide the overlay (Cmd+Shift+O)")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Picker("Show as", selection: $mode) {
                Text("Boxes").tag("box"); Text("Text").tag("text")
            }.pickerStyle(.segmented).disabled(!show)
            // All the fine-grained style controls live behind one button instead of each being
            // its own toolbar item — with Font/Background/Auto/Auto font all inline, this bar
            // overflowed past a handful of items and the rest silently landed in the hidden
            // ">>" menu, which is why the Background picker (and friends) seemed to vanish.
            Button { showStylePopover = true } label: { Image(systemName: "paintpalette") }
                .help("Overlay style")
                .popover(isPresented: $showStylePopover, arrowEdge: .bottom) {
                    let bgBinding = Binding<Color>(get: { bg }, set: { bgHex = $0.hexString })
                    VStack(alignment: .leading, spacing: 10) {
                        if mode == "text" {
                            HStack {
                                ColorPicker("Font", selection: txtBinding, supportsOpacity: false)
                                ColorPicker("Background", selection: bgBinding, supportsOpacity: false)
                            }
                            Toggle("Match text's own color automatically", isOn: $autoTextColor)
                                .help("Pick up the text's own ink color from the image and use it for the redrawn word; the Font color above is the fallback")
                            Toggle("Match background color automatically", isOn: $autoBg)
                                .help("Pick up the color immediately around each match and use it as its background; the Background color above is the fallback")
                            Toggle("Auto-match an installed font", isOn: $autoFont)
                                .help("Redraw each match in whichever installed font best matches it (or \(systemFontReplacement) if that's the system font), instead of the Font chosen in Settings")
                            Divider()
                            // Picking a specific font here overrides whatever auto-match found
                            // (or turns auto-match on, if it was off, so the pick takes effect
                            // immediately) — "Auto" reverts to the detected family.
                            HStack {
                                Text("Font").foregroundStyle(.secondary)
                                Spacer()
                                Picker("", selection: Binding<String>(
                                    get: { manualFont },
                                    set: { manualFont = $0; if !$0.isEmpty { autoFont = true } }
                                )) {
                                    Text(detectedFontName.map { "Auto (\($0))" } ?? "Auto").tag("")
                                    Divider()
                                    ForEach(candidateFontFamilies(), id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().frame(width: 170)
                            }
                            HStack {
                                Text("Size").foregroundStyle(.secondary)
                                Slider(value: $sizeScale, in: 0.5...1.5, step: 0.05)
                                Text("\(Int(sizeScale * 100))%").monospacedDigit().frame(width: 42, alignment: .trailing)
                            }
                            .help("Scales every match's fitted size up or down; 100% is the plain auto-fit")
                        } else {
                            ColorPicker("Box", selection: boxBinding, supportsOpacity: false)
                        }
                    }
                    .padding(14).frame(width: 300)
                }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            Button("Close") { NSApp.keyWindow?.close() }
        }
        .onExitCommand { NSApp.keyWindow?.close() }
        .task(id: path) {
            image = NSImage(contentsOfFile: path)
            failed = image == nil
            bgColors = []; textColors = []; matchedFonts = []; fontSizes = []; renderedFontNames = []; pixelSize = .zero
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
            textColors = await Task.detached(priority: .userInitiated) {
                sampledTextColors(at: p, rects: rects)
            }.value
            pixelSize = await Task.detached(priority: .userInitiated) { imagePixelSize(at: p) ?? .zero }.value
            if autoFont { await detectFonts() }
            await recomputeFontSizes()
            recomputeRenderedFontNames()
            scanning = false
        }
        .onChange(of: autoFont) { on in
            // Always redetect on turning on, rather than only when matchedFonts is still empty:
            // a prior attempt that legitimately found no match leaves it as a *non-empty* array
            // of nils (one per match), which made the old empty-check skip ever retrying and got
            // permanently stuck showing the manual Font/Weight fallback instead.
            Task {
                if on { await detectFonts() }
                await recomputeFontSizes()
                recomputeRenderedFontNames()
            }
        }
        .onChange(of: design) { _ in Task { await recomputeFontSizes() } }
        .onChange(of: weight) { _ in Task { await recomputeFontSizes(); recomputeRenderedFontNames() } }
        .onChange(of: manualFont) { _ in
            applyFontOverride()
            Task { await recomputeFontSizes(); recomputeRenderedFontNames() }
        }
        .onChange(of: sizeScale) { _ in Task { await recomputeFontSizes() } }
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
    /// Skipped unless auto-font is on, since scanning every candidate family is real work — only
    /// worth paying for when the feature is actually in use.
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

    /// The family actually rendered: `manualFont` when the user has picked one from the style
    /// popover's Font picker, otherwise whatever detectFonts() found. Re-run whenever either
    /// changes, without re-scanning the image (detectFonts already did the expensive part).
    private func applyFontOverride() {
        let effective = manualFont.isEmpty ? detectedFontName : manualFont
        matchedFonts = Array(repeating: effective, count: matches.count)
    }

    /// Cheap per-frame conversion of a match's cached native-pixel-scale font size (fontSizes,
    /// see recomputeFontSizes) to on-screen points — a single multiply, safe to call on every
    /// hover-move or resize instead of re-fitting from scratch.
    private func displayFontSize(_ i: Int, scale: CGFloat) -> CGFloat {
        (fontSizes.indices.contains(i) ? fontSizes[i] : 12) * scale
    }

    /// Fits each match's font size once, at the image's native pixel scale rather than the
    /// current window size, so it only needs recomputing when the matches, matched fonts,
    /// design or weight actually change — never on hover or window resize (the view just scales
    /// the cached result at render time via `displayFontSize(_:scale:)`).
    private func recomputeFontSizes() async {
        guard !matches.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { fontSizes = []; return }
        let items = matches.map { (text: $0.text, rect: $0.rect) }
        let mf = matchedFonts
        let af = autoFont, w = weight, d = design, px = pixelSize, scaleAdj = sizeScale
        fontSizes = await Task.detached(priority: .userInitiated) {
            items.enumerated().map { i, it in
                let box = CGSize(width: it.rect.width * px.width, height: it.rect.height * px.height)
                let family = i < mf.count ? mf[i] : nil
                let base = effectiveFontSize(for: it.text, weight: HL.fontWeight(w), design: HL.fontDesign(d),
                                              matchedFamily: family, autoFont: af, fitting: box)
                return max(base * scaleAdj, 4)   // sizeScale: user's manual nudge, see the Size control
            }
        }.value
    }

    /// Resolves each matched family to its exact renderable (PostScript) name once, instead of
    /// on every render — see renderableFontName.
    private func recomputeRenderedFontNames() {
        let bold = weight == "bold"
        renderedFontNames = matchedFonts.map { $0.map { renderableFontName(family: $0, bold: bold) } }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()
    @Environment(\.openWindow) private var openWindow
    @State private var showMiro = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search text inside images (FTS5: foo AND \"exact phrase\" bar*)", text: $m.query)
                    .textFieldStyle(.roundedBorder).onSubmit { m.search() }
                Picker("", selection: $m.searchMode) {
                    Text("Phrase").tag(SearchMode.phrase)
                    Text("Any word").tag(SearchMode.words)
                }
                .pickerStyle(.segmented).frame(width: 150)
                .help("Phrase: match the whole search text together, in order. Any word: match each word separately, anywhere.")
                .onChange(of: m.searchMode) { _ in m.search() }
                Button("Index folder…") { pick(dir: true) { m.index(folder: $0[0]) } }
                Button("Add files…") { pick(dir: false) { m.add(files: $0) } }
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                    Image(systemName: "gearshape")
                }.help("Settings (highlight color)")
            }.padding(10)
            Divider()
            List(m.results, selection: $m.selection) { hit in
                HStack(spacing: 10) {
                    Thumb(path: hit.path)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((hit.path as NSString).lastPathComponent).fontWeight(.medium)
                        Text(hit.snippet.isEmpty ? "(added manually)" : hit.snippet)
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Text((hit.path as NSString).deletingLastPathComponent)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode)) } label: { Image(systemName: "eye") }
                        .buttonStyle(.borderless).help("View full size")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode)) }
                .tag(hit.id)
            }
            Divider()
            HStack {
                Text(m.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                if m.busy { ProgressView().controlSize(.small) }
                if let l = m.link {
                    Button { NSWorkspace.shared.open(l) } label: { MiroBadge(size: 14); Text("Open board") }
                }
                Spacer()
                Button("Select all") { m.selection = Set(m.results.map(\.id)) }.disabled(m.results.isEmpty)
                Menu("Export to file") {
                    Button("CSV (path + OCR text)…") { m.exportToFile(.csv) }
                    Button("Markdown…") { m.exportToFile(.markdown) }
                    Button("Copy images to folder…") { m.exportToFile(.folder) }
                }.disabled(m.selection.isEmpty || m.busy).fixedSize()
                Button { showMiro = true } label: { MiroBadge(size: 14); Text("Export \(m.selection.count) to Miro…") }
                    .disabled(m.selection.isEmpty || m.busy).keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .sheet(isPresented: $showMiro) { MiroSheet(m: m, isPresented: $showMiro) }
    }

    private func pick(dir: Bool, _ done: @escaping ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = dir; p.canChooseFiles = !dir; p.allowsMultipleSelection = !dir
        if p.runModal() == .OK, !p.urls.isEmpty { done(p.urls) }
    }
}

struct MiroSheet: View {
    @ObservedObject var m: Model
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MiroBadge(size: 28)
                Text("Export to Miro").font(.headline)
            }
            SecureField("Miro access token (boards:read, boards:write) — saved in Keychain", text: $m.token)
            TextField("Existing board ID (leave empty to create a new board)", text: $m.boardID)
            TextField("New board name", text: $m.boardName).disabled(!m.boardID.isEmpty)
            Text("\(m.selection.count) item(s): images plus their OCR snippets as sticky notes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Export") { isPresented = false; m.exportSelection() }
                    .keyboardShortcut(.defaultAction).disabled(m.token.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}
