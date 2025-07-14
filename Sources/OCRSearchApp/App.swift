import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import OCRSearchCore

/// Sources/assets/icon-1024.png — the composed app icon (see Scripts/make-icon.swift), resolved
/// relative to this source file's own location (not the process's current working directory) so
/// it's found the same way regardless of how the app was launched. Used for the Dock icon at
/// runtime and for MiroBadge, so both match the icon the bundle ships.
///
/// Not logo.png, which despite appearances is fully opaque: its "transparent" background is a
/// checkerboard painted into the pixels, so it renders as a literal checkered square anywhere it
/// is drawn.
let appLogo: NSImage? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // App.swift -> Sources/OCRSearchApp/
        .deletingLastPathComponent()   // -> Sources/
        .appendingPathComponent("assets/icon-1024.png")
    return NSImage(contentsOfFile: url.path)
}()

/// The miro badge stamped on the bottom-right of every opened image (see PreviewView) and on
/// every exported one (see drawWatermark) — drawn rather than loaded, from the wordmark in
/// Sources/assets/watermark.svg, resolved the same way as appLogo.
///
/// Vector, not a bitmap: NSImage keeps an SVG as an _NSSVGImageRep and rasterises it at whatever
/// size it is drawn at, so the same artwork is sharp in a scaled-down preview and in a
/// full-resolution export. The bitmap it replaces could only be upscaled.
let watermarkArtwork: NSImage? = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("assets/watermark.svg")
    return NSImage(contentsOf: url)
}()

/// Badge geometry in the image's own pixels: a 63x34 badge sitting 20px in from the right edge
/// and 20px up from the bottom. The size and the bottom offset are what the reference screenshot
/// that already carried this watermark uses (miro-files/IMG_0849.PNG); its right offset measured
/// 21px, squared off to 20 here so the badge is inset equally on both edges.
///
/// Fixed pixels, not fractions of the image: the badge is meant to be that size, full stop, the
/// way a real watermark is stamped at one size rather than growing with the canvas. (It was
/// fractional before, which happened to give exactly 63x34 on the 1356px-wide reference and
/// something smaller on every other image.) The trade-off is that on a much larger image the
/// badge is proportionally smaller — deliberate, but the numbers to change are right here.
let watermarkPixelSize = CGSize(width: 63, height: 34)
let watermarkRightMargin: CGFloat = 20
let watermarkBottomMargin: CGFloat = 20
/// Corner rounding as a fraction of the badge's height, and the share of the badge's width the
/// wordmark spans — both taken from the reference badge, which leaves about 16% padding either
/// side of the wordmark. The wordmark is then centred on both axes, unlike the reference, where
/// it sat noticeably high (24% clearance above, 31% below).
let watermarkCornerFraction: CGFloat = 0.2
let watermarkWordmarkWidthFraction: CGFloat = 0.68
/// 50% grey. The badge lands on screenshots of any colour, so it is translucent rather than a
/// solid chip.
let watermarkBackground = Color(white: 0.5, opacity: 0.5)
/// Applied to the badge as a whole, on top of the translucency already in watermarkBackground.
/// The badge carries its own 50% now, so this stays at 1 — it is the single knob for fading the
/// whole thing, wordmark included, without touching the background colour.
let watermarkOpacity: Double = 1

/// Small rounded Miro logo badge, marking the app's Miro-related actions (export button, the
/// export sheet, "open board"). Square, dark card with the wordmark baked in — looks right at
/// any size without needing its own background.
struct MiroBadge: View {
    var size: CGFloat = 16
    var body: some View {
        Group {
            if let appLogo {
                Image(nsImage: appLogo).resizable().scaledToFit()
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
        WindowGroup("Miro-ocr-search") { ContentView().frame(minWidth: 760, minHeight: 520) }
        // Full-size viewer: one window per image, closable with the red button, Cmd+W or Esc.
        WindowGroup("Preview", id: "preview", for: PreviewRequest.self) { $req in
            if let req { PreviewView(allPaths: req.allPaths, startIndex: req.startIndex, query: req.query, searchMode: req.mode) }
        }.defaultSize(width: 620, height: 900)
        Settings { SettingsView() }
    }
}

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

/// One match's original text as measured off the image: the colour of its glyphs, and the box
/// those glyphs actually occupy (normalised, bottom-left origin, like Vision's rects). Both come
/// out of the same single pixel scan, since finding the ink is most of the work either way.
struct InkSample: Sendable {
    var rect: CGRect
    var color: Color
}

/// Approximate the color of the text itself within each match box, for text-overlay mode to draw
/// the redrawn word in — rather than always using the manually picked Font color. Samples a grid
/// of points inside the box, first finding the box's background reference the same way
/// sampledBackgroundColors does (its edge midpoints, just outside the box), then averaging
/// whichever interior samples differ *most* from that background — those are the ones most
/// likely to have landed on actual glyph ink rather than background showing through between or
/// around the letters. Falls back to `nil` if the image can't be read as a bitmap, or nothing
/// inside the box stands out from its background at all (e.g. blank space).
func sampledInk(at path: String, rects: [CGRect]) -> [InkSample?] {
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
    func sample(_ rect: CGRect) -> InkSample? {
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

        // Walk the box's pixels rather than a 6x6 grid of them. Most of any match box is
        // background — text has gaps, and glyphs are thin — so a grid that coarse landed only a
        // handful of points on ink at all, and those were as likely to be on an antialiased edge
        // as on the solid middle of a stroke. Stepped only if the box is unusually large, since
        // colorAt(x:y:) allocates an NSColor per call.
        let pxX0 = max(Int(x0 * CGFloat(w)), 0), pxX1 = min(Int(x1 * CGFloat(w)), w - 1)
        let pxY0 = max(Int(yTop * CGFloat(h)), 0), pxY1 = min(Int(yBottom * CGFloat(h)), h - 1)
        guard pxX1 > pxX0, pxY1 > pxY0 else { return nil }
        let area = (pxX1 - pxX0) * (pxY1 - pxY0)
        let step = max(1, Int((Double(area) / 40_000).squareRoot().rounded(.up)))

        var candidates: [(r: CGFloat, g: CGFloat, b: CGFloat, distance: CGFloat, x: Int, y: Int)] = []
        candidates.reserveCapacity(area / (step * step) + 1)
        for py in stride(from: pxY0, through: pxY1, by: step) {
            for px in stride(from: pxX0, through: pxX1, by: step) {
                guard let c = rep.colorAt(x: px, y: py) else { continue }
                let dr = c.redComponent - bgR, dg = c.greenComponent - bgG, db = c.blueComponent - bgB
                candidates.append((c.redComponent, c.greenComponent, c.blueComponent,
                                   dr * dr + dg * dg + db * db, px, py))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.distance > $1.distance }

        // The peak is taken a little way into the sorted run rather than as the single maximum,
        // so one stray pixel — a compression artefact, part of an icon clipped into the box —
        // cannot define the ink colour on its own.
        let peak = candidates[min(candidates.count - 1, candidates.count / 50)].distance
        guard peak > 0.001 else { return nil }   // nothing stood out from the background

        // Average only the pixels at that peak: the solid interior of the strokes. Everything
        // below it is the antialiased ramp from ink to background, which is by definition a
        // blend of the two, so including it drags the answer towards the background — which is
        // exactly what made white text come out as grey (measured: #EFEFEF instead of white),
        // and what put a colour cast on it when the channels did not blend evenly. Distance is
        // squared, so 0.9 here keeps only pixels about 95% of the way to full ink.
        let core = candidates.prefix { $0.distance >= peak * 0.9 }

        // Within that core, take the most common exact colour rather than the average of them.
        // Flat UI text is a plateau of identical pixels with a thin shoulder of near-misses
        // around it, and averaging still lets that shoulder pull the answer off: measured on a
        // heading whose glyphs are 255 across 204 pixels, the mean came back 253. The mode lands
        // on the plateau exactly. It is only trusted when the plateau is a real one — for text
        // over a gradient, or photographic text, there is no single dominant value and the mean
        // of the core is the better answer.
        var tally: [Int: Int] = [:]
        for c in core {
            let key = (Int((c.r * 255).rounded()) << 16)
                    | (Int((c.g * 255).rounded()) << 8)
                    | Int((c.b * 255).rounded())
            tally[key, default: 0] += 1
        }
        var color: Color
        if let (key, count) = tally.max(by: { $0.value < $1.value }), count * 10 >= core.count {
            color = Color(.sRGB, red: Double((key >> 16) & 255) / 255,
                          green: Double((key >> 8) & 255) / 255,
                          blue: Double(key & 255) / 255, opacity: 1)
        } else {
            let n = CGFloat(core.count)
            color = Color(.sRGB, red: core.reduce(0) { $0 + $1.r } / n,
                          green: core.reduce(0) { $0 + $1.g } / n,
                          blue: core.reduce(0) { $0 + $1.b } / n, opacity: 1)
        }

        // The box those glyphs actually occupy. Taken at a quarter of the peak distance — about
        // halfway up the antialiased ramp, which is where a glyph's edge visually is — rather
        // than at the peak, since the extent has to include the softened outside of a stroke, not
        // just its solid middle.
        //
        // This is the measurement the overlay is sized and placed against, and it is why:
        // Vision's box is NOT a tight wrap around the glyphs, whatever its reputation. Measured
        // on IMG_0849 it runs 8-11% taller than the ink inside it and starts several pixels to
        // the left, so deriving a font size from the box's height came out that much too big and
        // deriving a left edge from the box's edge started that much too early.
        let edge = peak * 0.25
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for c in candidates where c.distance >= edge {
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Back to normalised, bottom-left origin, matching Vision's own rects.
        let inkRect = CGRect(x: CGFloat(minX) / CGFloat(w),
                             y: 1 - CGFloat(maxY + step) / CGFloat(h),
                             width: CGFloat(maxX + step - minX) / CGFloat(w),
                             height: CGFloat(maxY + step - minY) / CGFloat(h))
        return InkSample(rect: inkRect, color: color)
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
            else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
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
    /// Mirrors the GeometryReader's `scale` (display points per native image pixel) outside of
    /// it, so the toolbar's Size field — which lives in .toolbar, with no access to that
    /// GeometryReader — can show and set a size in the same on-screen points the user actually
    /// sees, matching how every other text-size field works, rather than some internal unit.
    @State private var displayScale: CGFloat = 1
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
    @AppStorage(HL.manualSize) private var manualSize: Double = 0
    @AppStorage(HL.italic) private var italic = false

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
                            if show, let overlayLayer {
                                Image(nsImage: overlayLayer).resizable()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .allowsHitTesting(false)
                            }
                            // Invisible, and only for hit testing: the overlay itself is one
                            // image now, so each match still needs its own target for the hover
                            // card to know which one the cursor is over.
                            ForEach(Array((show ? matches : []).enumerated()), id: \.offset) { i, m in
                                let w = m.rect.width * geo.size.width + matchBoxPadding
                                let h = m.rect.height * geo.size.height + matchBoxPadding
                                Color.clear.contentShape(Rectangle())
                                    .frame(width: w, height: h)
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
                                               textColor: (autoTextColor ? inkSamples[safe: i] ?? nil : nil)?.color ?? txt,
                                               bgColor: (autoBg ? (bgColors.indices.contains(i) ? bgColors[i] : nil) : nil) ?? bg,
                                               opacity: opacity, matchedFont: mf, autoFont: autoFont,
                                               fontIsManual: !manualFont.isEmpty)
                                    .allowsHitTesting(false)   // never steals hover from the match it describes
                                    .position(x: min(hoverPoint.x + 110, geo.size.width - 100),
                                              y: min(hoverPoint.y + 70, geo.size.height - 60))
                            }
                            // Stamped on every opened image, independent of search matches/overlay
                            // state. Sized and placed in the image's own pixels and then scaled to
                            // the window, so the preview shows the badge at the same size relative
                            // to the image that an export writes -- see watermarkPixelSize.
                            let ww = watermarkPixelSize.width * scale
                            let wh = watermarkPixelSize.height * scale
                            ZStack {
                                RoundedRectangle(cornerRadius: wh * watermarkCornerFraction)
                                    .fill(watermarkBackground)
                                if let watermarkArtwork {
                                    Image(nsImage: watermarkArtwork).resizable().scaledToFit()
                                        .frame(width: ww * watermarkWordmarkWidthFraction)
                                }
                            }
                            .frame(width: ww, height: wh)
                            .opacity(watermarkOpacity)
                            .allowsHitTesting(false)
                            .position(x: geo.size.width - watermarkRightMargin * scale - ww / 2,
                                      y: geo.size.height - watermarkBottomMargin * scale - wh / 2)
                        }
                        .coordinateSpace(name: "preview")
                        .onAppear { setDisplayScale(scale) }
                        .onChange(of: geo.size) { _ in setDisplayScale(pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1) }
                        .onChange(of: pixelSize) { _ in setDisplayScale(pixelSize.width > 0 ? geo.size.width / pixelSize.width : 1) }
                    })
                    .padding(12)
            }
            else if failed { Text("Can't open \(path)").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(minWidth: 400, minHeight: 400)
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar {
            if allPaths.count > 1 {
                Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0).help("Previous result (⌘[)").accessibilityLabel("Previous result")
                    .keyboardShortcut("[", modifiers: .command)
                Text("\(index + 1) of \(allPaths.count)").foregroundStyle(.secondary).monospacedDigit()
                Button { index += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= allPaths.count - 1).help("Next result (⌘])").accessibilityLabel("Next result")
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
            }
            Text(scanning ? "Finding matches…" : (searchTerms(query, mode: searchMode).isEmpty ? "" : (show ? plural(matches.count, "match") : "overlay off")))
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
                .help("Overlay style").accessibilityLabel("Overlay style")
                .popover(isPresented: $showStylePopover, arrowEdge: .bottom) {
                    let bgBinding = Binding<Color>(get: { bg }, set: { bgHex = $0.hexString })
                    // Grouped into labelled sections rather than one flat stack of controls —
                    // it had grown to two color pickers, three auto-match toggles and a whole
                    // font row with no hierarchy to read it by.
                    VStack(alignment: .leading, spacing: 14) {
                        if mode == "text" {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Color")
                                HStack {
                                    ColorPicker("Text", selection: txtBinding, supportsOpacity: false)
                                    ColorPicker("Background", selection: bgBinding, supportsOpacity: false)
                                }
                                Toggle("Match text color from image", isOn: $autoTextColor)
                                    .help("Pick up the text's own ink color from the image and use it for the redrawn word; the Text color above is the fallback")
                                Toggle("Match background from image", isOn: $autoBg)
                                    .help("Pick up the color immediately around each match and use it as its background; the Background color above is the fallback")
                            }
                            Divider()
                            // Laid out like an ordinary text-editing toolbar (font, point size,
                            // then Bold/Italic toggles) rather than a settings-style option list.
                            // Picking a font or typing a size overrides whatever auto-match/fit
                            // found (and turns auto-match on, if it was off, so the change takes
                            // visible effect immediately); "Auto" in the font menu, or the Reset
                            // button once anything is overridden, goes back to automatic.
                            let hoveredOrFirstSize: Double = {
                                let idx = hoverIndex ?? 0
                                let native = fontSizes.indices.contains(idx) ? fontSizes[idx] : 17
                                return Double((native * displayScale).rounded())
                            }()
                            let sizeBinding = Binding<Double>(
                                get: { manualSize > 0 ? manualSize : hoveredOrFirstSize },
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
                                    guard manualSize > 0 || abs(v - hoveredOrFirstSize) >= 0.5 else { return }
                                    manualSize = v
                                }
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Font")
                                Toggle("Match font from image", isOn: $autoFont)
                                    .help("Redraw each match in whichever installed font best matches it (or \(systemFontReplacement) if that's the system font)")
                                HStack(spacing: 8) {
                                    Picker("", selection: Binding<String>(
                                        get: { manualFont },
                                        set: { manualFont = $0; if !$0.isEmpty { autoFont = true } }
                                    )) {
                                        Text(detectedFontName.map { "Auto (\($0))" } ?? "Auto").tag("")
                                        Divider()
                                        ForEach(candidateFontFamilies(), id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden().frame(width: 148)

                                    TextField("", value: sizeBinding, format: .number)
                                        .textFieldStyle(.roundedBorder).frame(width: 38)
                                        .multilineTextAlignment(.trailing)
                                    Stepper("", value: sizeBinding, in: 1...400).labelsHidden()
                                    Text("pt").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    Toggle(isOn: Binding(get: { weight == "bold" }, set: { weight = $0 ? "bold" : "regular" })) {
                                        Text("B").bold()
                                    }.toggleStyle(.button).help("Bold").accessibilityLabel("Bold")
                                    Toggle(isOn: $italic) {
                                        Text("I").italic()
                                    }.toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
                                    Spacer()
                                    if !manualFont.isEmpty || manualSize > 0 || weight == "bold" || italic {
                                        Button("Reset to auto") {
                                            manualFont = ""; manualSize = 0; weight = "regular"; italic = false
                                        }
                                        .font(.caption).buttonStyle(.link)
                                        .help("Back to auto-matched font/size, regular weight, no italic")
                                    }
                                }
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Preview")
                                stylePreview(box: box, text: txt, background: bg)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Box")
                                ColorPicker("Color", selection: boxBinding, supportsOpacity: false)
                                HStack {
                                    Text("Fill")
                                    Slider(value: $opacity, in: 0...0.8)
                                    Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                                }
                                Toggle("Outline", isOn: $outline)
                            }
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Preview")
                                stylePreview(box: box, text: txt, background: bg)
                            }
                        }
                    }
                    .padding(14).frame(width: 300)
                }
            Button(action: saveImage) { Label("Save Image…", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s")
                .help("Write this image, with its overlays and watermark, to a PNG file")
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button { NSApp.keyWindow?.close() } label: { Label("Close", systemImage: "xmark.circle") }
        }
        .onExitCommand { NSApp.keyWindow?.close() }
        .task(id: path) {
            image = NSImage(contentsOfFile: path)
            failed = image == nil
            bgColors = []; inkSamples = []; matchedFonts = []; fontSizes = []; renderedFontNames = []; pixelSize = .zero
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
            if autoFont { await detectFonts() }
            await recomputeFontSizes()
            recomputeRenderedFontNames()
            rebuildOverlay()
            scanning = false
        }
        .onChange(of: [mode, boxHex, textHex, bgHex, design, weight, manualFont,
                       "\(show)", "\(opacity)", "\(outline)", "\(autoTextColor)",
                       "\(autoBg)", "\(manualSize)", "\(italic)"]) { _ in rebuildOverlay() }
        .onChange(of: autoFont) { on in
            // Always redetect on turning on, rather than only when matchedFonts is still empty:
            // a prior attempt that legitimately found no match leaves it as a *non-empty* array
            // of nils (one per match), which made the old empty-check skip ever retrying and got
            // permanently stuck showing the manual Font/Weight fallback instead.
            Task {
                if on { await detectFonts() }
                await recomputeFontSizes()
                recomputeRenderedFontNames()
                rebuildOverlay()
            }
        }
        .onChange(of: design) { _ in Task { await recomputeFontSizes(); rebuildOverlay() } }
        .onChange(of: weight) { _ in Task { await recomputeFontSizes(); recomputeRenderedFontNames(); rebuildOverlay() } }
        .onChange(of: manualFont) { _ in
            applyFontOverride()
            Task { await recomputeFontSizes(); recomputeRenderedFontNames(); rebuildOverlay() }
        }
    }

    /// Everything the shared overlay drawing needs, from what this window has already computed —
    /// no second OCR pass, and guaranteed to be the same inputs the on-screen layer was built
    /// from, so a Save writes exactly what is being looked at.
    private func currentPlan() -> RenderPlan {
        RenderPlan(pixelSize: pixelSize, matches: show ? matches : [], bgColors: bgColors,
                   ink: inkSamples, matchedFonts: matchedFonts, fontSizes: fontSizes)
    }

    /// Redraws the overlay layer. Cheap relative to the scan that produced its inputs (no OCR, no
    /// pixel sampling), and it does not depend on the window's size — the layer is drawn at the
    /// image's native resolution and scaled down with the photo — so resizing never triggers it.
    private func rebuildOverlay() {
        guard pixelSize.width > 0 else { overlayLayer = nil; return }
        overlayLayer = overlayLayerImage(plan: currentPlan(), style: OverlayStyle.current())
    }

    /// Tracks how big the image is being drawn, and persists it (HL.manualSizeScale) so the
    /// exporter can translate the point-based settings — a manually typed font size, the match
    /// box padding, the outline width — back into the image's own pixels. Kept in step with the
    /// window rather than snapshotted when a size is typed, because those settings are in points
    /// and so their meaning genuinely changes as the window resizes: a fixed 24pt covers twice as
    /// much of the image at 40% zoom as at 80%. Syncing it means an export always reproduces what
    /// the window is showing right now.
    private func setDisplayScale(_ s: CGFloat) {
        displayScale = s
        if s > 0 { UserDefaults.standard.set(Double(s), forKey: HL.manualSizeScale) }
    }

    /// Writes what is on screen — image, overlays, watermark — to a PNG the user picks.
    /// Hands the renderer the window's already-computed matches, sampled colours, matched font
    /// and fitted sizes instead of letting it redo the work: that is a second or more of OCR per
    /// image, and reusing them also guarantees the file is exactly what is being looked at rather
    /// than a fresh pass that could resolve a detail differently.
    private func saveImage() {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name)-overlay.png"
        panel.allowedContentTypes = [.png]
        panel.message = "Saved with the overlays and watermark as shown, at the image's full resolution."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let plan = currentPlan()
        guard let data = renderExportPNG(path: path, query: query, searchMode: searchMode,
                                         style: OverlayStyle.current(), plan: plan) else { return }
        try? data.write(to: url)
    }

    /// Small all-caps caption used to head each group of controls in the style popover — the
    /// popover had grown well past the point where one flat stack of rows was readable.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold).kerning(0.5)
            .foregroundStyle(.secondary)
    }

    /// Live swatch at the foot of the style popover, drawn with exactly the settings above it.
    /// Unlike the Settings window's generic preview it uses this image's real data — the hovered
    /// (or first) match's text, its sampled colors and its auto-matched font — so the popover
    /// shows what the change will actually look like here, without hunting for the match on the
    /// page behind the popover.
    private func stylePreview(box: Color, text textColor: Color, background: Color) -> some View {
        let i = hoverIndex ?? 0
        let sample = matches.indices.contains(i) ? matches[i].text : "Screen Active"
        let size = CGSize(width: 190, height: 30)
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.25))
            MatchView(text: sample, size: size, mode: mode,
                      box: box, textColor: textColor, opacity: opacity, outline: outline,
                      design: design, weight: weight,
                      sampled: bgColors.indices.contains(i) ? bgColors[i] : nil, background: background,
                      autoBackground: autoBg,
                      matchedFont: matchedFonts.indices.contains(i) ? matchedFonts[i] : nil,
                      autoFont: autoFont,
                      fontSize: min(displayFontSize(i, scale: displayScale), size.height),
                      renderedFontName: renderedFontNames.indices.contains(i) ? renderedFontNames[i] : nil,
                      sampledTextColor: inkSamples.indices.contains(i) ? inkSamples[i]?.color : nil,
                      autoTextColor: autoTextColor, italic: italic)
        }
        .frame(maxWidth: .infinity).frame(height: 44)
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
    /// hover-move or resize instead of re-fitting from scratch. `manualSize`, when set, is
    /// already in on-screen points (that's what the toolbar's Size field shows and edits), so it
    /// bypasses the native-pixel cache and scale multiply entirely — every match gets exactly
    /// that point size, the same way setting a size in any text editor applies to the whole
    /// selection rather than scaling each run individually.
    private func displayFontSize(_ i: Int, scale: CGFloat) -> CGFloat {
        if manualSize > 0 { return manualSize }
        return (fontSizes.indices.contains(i) ? fontSizes[i] : 12) * scale
    }

    /// Fits each match's font size once, at the image's native pixel scale rather than the
    /// current window size, so it only needs recomputing when the matches, matched fonts,
    /// design or weight actually change — never on hover or window resize (the view just scales
    /// the cached result at render time via `displayFontSize(_:scale:)`).
    private func recomputeFontSizes() async {
        guard !matches.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { fontSizes = []; return }
        let items = matches.map { (text: $0.text, rect: $0.rect) }
        let mf = matchedFonts, ink = inkSamples
        let af = autoFont, w = weight, d = design, px = pixelSize
        fontSizes = await Task.detached(priority: .userInitiated) {
            items.enumerated().map { i, it in
                let family = i < mf.count ? mf[i] : nil
                // Fit to the glyphs measured off the image, falling back to Vision's box only
                // when they could not be isolated — see inkFittedFontSize for why the box makes
                // a poor ruler.
                if let measured = ink[safe: i] ?? nil, measured.rect.height * px.height > 1 {
                    return inkFittedFontSize(for: it.text, weight: HL.fontWeight(w), design: HL.fontDesign(d),
                                             matchedFamily: family, autoFont: af,
                                             fitting: CGSize(width: measured.rect.width * px.width,
                                                             height: measured.rect.height * px.height))
                }
                let box = CGSize(width: it.rect.width * px.width, height: it.rect.height * px.height)
                return effectiveFontSize(for: it.text, weight: HL.fontWeight(w), design: HL.fontDesign(d),
                                         matchedFamily: family, autoFont: af, fitting: box)
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
                TextField("Search text inside images", text: $m.query)
                    .textFieldStyle(.roundedBorder).onSubmit { m.search() }
                    .help("Type any text and press Return. Advanced: AND / OR / NOT, \"exact phrase\", word* — see the FTS5 query syntax.")
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
                }.help("Settings (highlight color)").accessibilityLabel("Settings")
            }.padding(10)
            Divider()
            if m.results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(m.query.isEmpty ? "No images indexed yet" : "No matches for “\(m.query)”")
                        .font(.title3).foregroundStyle(.secondary)
                    if m.query.isEmpty {
                        Text("Index a folder of screenshots to start searching their text.")
                            .font(.callout).foregroundStyle(.tertiary)
                        Button("Index folder…") { pick(dir: true) { m.index(folder: $0[0]) } }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
                        Button { openPreview(hit) } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless).help("View full size").accessibilityLabel("View full size")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openPreview(hit) }
                    .tag(hit.id)
                }
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
                    Divider()
                    Button("Images with overlay…") { m.exportToFile(.images) }
                }.disabled(m.selection.isEmpty || m.busy).fixedSize()
                Button { showMiro = true } label: { MiroBadge(size: 14); Text("Export \(m.selection.count) to Miro…") }
                    .disabled(m.selection.isEmpty || m.busy).keyboardShortcut(.defaultAction)
            }.padding(10)
        }
        .sheet(isPresented: $showMiro) { MiroSheet(m: m, isPresented: $showMiro) }
    }

    /// Opens the preview on `hit`, but hands it the whole current result list so its toolbar can
    /// page Previous/Next through the other results without coming back here.
    private func openPreview(_ hit: Hit) {
        let paths = m.results.map(\.path)
        openWindow(id: "preview", value: PreviewRequest(path: hit.path, query: m.query, mode: m.searchMode,
                                                        allPaths: paths,
                                                        startIndex: paths.firstIndex(of: hit.path) ?? 0))
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
    /// "Create a new board" vs "add to an existing one" — previously both fields were always
    /// visible with the board-name one conditionally disabled, which left the user to infer the
    /// relationship between them.
    @State private var useExistingBoard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                MiroBadge(size: 28)
                Text("Export to Miro").font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Access token").font(.subheadline)
                    Spacer()
                    Link("Where do I get one?", destination: URL(string: "https://miro.com/app/settings/user-profile/apps")!)
                        .font(.caption)
                }
                SecureField("Miro access token", text: $m.token)
                Text("Needs the boards:read and boards:write scopes. Saved in your Keychain, not in the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $useExistingBoard) {
                Text("Create a new board").tag(false)
                Text("Add to an existing board").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: useExistingBoard) { existing in if !existing { m.boardID = "" } }

            if useExistingBoard {
                TextField("Board ID", text: $m.boardID)
            } else {
                TextField("New board name", text: $m.boardName)
            }

            Text("\(plural(m.selection.count, "item")): images plus their OCR snippets as sticky notes.")
                .font(.caption).foregroundStyle(.secondary)

            if let err = m.exportError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if m.busy { ProgressView().controlSize(.small); Text("Exporting…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { isPresented = false }
                // Stays open while exporting, so progress and any failure land here rather than
                // in a status line behind the sheet; dismisses itself once a board link arrives.
                Button("Export") { m.exportSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.token.isEmpty || m.busy)
            }
        }
        .padding(20).frame(width: 480)
        .onChange(of: m.link) { link in if link != nil { isPresented = false } }
    }
}
