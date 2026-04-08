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

/// The app's file panels, built once at launch and reused.
///
/// -[NSSavePanel init] is not a cheap constructor. It opens a connection to an out-of-process
/// ViewBridge service and blocks the main thread on a nested run loop until that service answers.
/// Sampled during a hang, the app sat in exactly that frame — _initBridgeAndStuff waiting on an
/// NSCFRunLoopSemaphore — for 2380 of 2380 samples, with no panel service process ever having
/// started for it.
///
/// Why that stall happens is still unknown: it did not reproduce here with stale services present,
/// launched directly or through LaunchServices, in full screen, on repeated opening and
/// dismissing, or from a menu item's action — every one of those built a panel in about a third of
/// a second. What is known is where it blocks, and that building a panel at launch has been fast
/// in every run. So the construction happens once, at launch, and opening a file afterwards only
/// calls begin(), which does not touch the bridge.
///
/// A reused panel keeps its settings between uses, so every caller sets the ones it cares about.
@MainActor enum Panels {
    static let open = NSOpenPanel()
    static let save = NSSavePanel()

    /// Builds both now, so neither is built in response to a click.
    static func warmUp() { _ = open; _ = save }

    /// An open panel reset to a known state. `dir` picks folders, otherwise files.
    static func openPanel(dir: Bool) -> NSOpenPanel {
        let p = open
        p.canChooseDirectories = dir
        p.canChooseFiles = !dir
        p.allowsMultipleSelection = !dir
        p.prompt = nil
        p.message = nil
        return p
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)      // needed when launched via `swift run`
        Panels.warmUp()   // see Panels: never build one under a click
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

/// Pixels per point for an image: 2 for a screenshot saved at 144 dpi, 1 for one at 72.
///
/// This folder mixes both — IMG_0849 is 1356x2948 at 72 dpi while the rest are 1206x2622 at 144 —
/// which is exactly why a size expressed in pixels means a different apparent size from one image
/// to the next. Sizes the user sets and reads are in points, the unit that means the same thing
/// everywhere; this is what converts them for drawing.
func imagePointScale(at path: String) -> CGFloat {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat, dpi > 0 else { return 1 }
    return max(1, (dpi / 72).rounded())
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

/// Where a glyph's edge is taken to be, as a fraction of the peak squared distance from the
/// background. Everything the overlay draws is fitted to the box this produces, so it decides how
/// big the redrawn text comes out.
///
/// It started at 0.25 — the half-way point of the antialiased ramp, since distance is squared, and
/// where a glyph outline nominally sits. Right for a clean outline, wrong for a screenshot: text
/// on an image carries a softer skirt than the geometry suggests, so 0.25 clipped the outermost
/// lit row off every measurement and every fit came out slightly small.
///
/// Calibrated instead, over 30 cases (ten matches across five screenshots, each in three fonts),
/// by rendering the fit and comparing its ink against the original's:
///
///     edge   mean bias   mean |error|   worst
///     0.25     -1.05%       2.43%        7.7%
///     0.20     -0.79%       2.17%        7.7%
///     0.16     -0.05%       1.43%        5.1%
///     0.12     +0.87%       1.89%        6.9%
///     0.08     +1.42%       2.45%        6.9%
///
/// 0.16 is the turning point on all three measures at once, which is what makes it a calibration
/// rather than a number that suited one screenshot.
let inkEdgeFraction: CGFloat = 0.16

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
        let edge = peak * inkEdgeFraction
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
    /// matchedFonts (which holds the *effective* family, i.e. `style.manualFont` when it's set) purely
    /// so the toolbar can style.show the user what auto-detection found, even while overridden.
    @State private var detectedFontName: String?
    @State private var pixelSize: CGSize = .zero
    /// Pixels per point for this image; see imagePointScale. Sizes shown and typed are points.
    @State private var imageScale: CGFloat = 1
    /// Fitted font size per match, computed once at the image's native pixel scale rather than
    /// on demand — fitting takes several font-metric lookups, and computing it live inside
    /// MatchView/MatchInfoPopup's body meant it re-ran on every mouse-move while hovering *any*
    /// match, for *every* visible match, which was especially slow with auto-font on (family
    /// lookups, not just system-font construction). Scaled to the actual on-screen size at
    /// render time (a cheap multiply) via displayFontSize(_:in:).
    @State private var fontSizes: [CGFloat] = []
    /// Letter spacing fitted per match, alongside the sizes and for the same reason: it depends on
    /// the font, so it is worked out again whenever the font, weight or size changes.
    @State private var trackings: [CGFloat] = []
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
    /// GeometryReader — can style.show and set a size in the same on-screen points the user actually
    /// sees, matching how every other text-size field works, rather than some internal unit.
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
        let boxBinding = Binding<Color>(get: { box }, set: { style.boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { style.textHex = $0.hexString })
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
                                        if style.show, let overlayLayer {
                                            Image(nsImage: overlayLayer).resizable()
                                                .frame(width: geo.size.width, height: geo.size.height)
                                                .allowsHitTesting(false)
                                        }
                                        // Invisible, and only for hit testing: the overlay itself is one
                                        // image now, so each match still needs its own target for the hover
                                        // card to know which one the cursor is over.
                                        ForEach(Array((style.show ? matches : []).enumerated()), id: \.offset) { i, m in
                                            let padH = m.rect.height * geo.size.height * matchBoxPaddingFraction
                                            let w = m.rect.width * geo.size.width + padH
                                            let h = m.rect.height * geo.size.height + padH
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
                                            let padH = m.rect.height * geo.size.height * matchBoxPaddingFraction
                                            let w = m.rect.width * geo.size.width + padH
                                            let h = m.rect.height * geo.size.height + padH
                                            let mf = matchedFonts.indices.contains(i) ? matchedFonts[i] : nil
                                            MatchInfoPopup(text: m.text, mode: style.mode,
                                                           count: matches.filter { $0.text.caseInsensitiveCompare(m.text) == .orderedSame }.count,
                                                           boxSize: CGSize(width: w, height: h),
                                                           fontSize: imageFontSize(i),
                                                           design: style.design, weight: style.weight,
                                                           boxColor: box,
                                                           textColor: (style.autoTextColor ? inkSamples[safe: i] ?? nil : nil)?.color ?? txt,
                                                           bgColor: (style.autoBg ? (bgColors.indices.contains(i) ? bgColors[i] : nil) : nil) ?? bg,
                                                           opacity: style.opacity, matchedFont: mf,
                                                           fontIsManual: !style.manualFont.isEmpty)
                                                .allowsHitTesting(false)   // never steals hover from the match it describes
                                                .position(x: min(hoverPoint.x + 110, geo.size.width - 100),
                                                          y: min(hoverPoint.y + 70, geo.size.height - 60))
                                        }
                                        // Follows the overlay toggle: turning the overlay off shows the
                                        // image as it is, and a watermark left behind would contradict
                                        // that. Sized and placed in the image's own pixels and then
                                        // scaled to the window, so the preview shows the badge at the
                                        // same size relative to the image that an export writes --
                                        // see watermarkPixelSize.
                                        let ww = watermarkPixelSize.width * scale
                                        let wh = watermarkPixelSize.height * scale
                                        if style.show {
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
            // Zoom sits with the other view controls, left of everything that changes how the
            // overlay is drawn, since it changes only how the image is displayed.
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
                .keyboardShortcut("-", modifiers: .command)
                .disabled(displayScale <= Self.zoomRange.lowerBound)
            Menu {
                Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                Button("Actual Size") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
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
                .keyboardShortcut("+", modifiers: .command)
                .disabled(displayScale >= Self.zoomRange.upperBound)
            Divider()

            Text(scanning ? "Finding matches…" : (searchTerms(query, mode: searchMode).isEmpty ? "" : (style.show ? plural(matches.count, "match") : "overlay off")))
                .foregroundStyle(.secondary)
            Toggle("Overlay", isOn: $style.show)
                .toggleStyle(.switch).help("Show or hide the overlay (Cmd+Shift+O)")
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Picker("Show as", selection: $style.mode) {
                Text("Boxes").tag("box"); Text("Text").tag("text")
            }.pickerStyle(.segmented).disabled(!style.show)
            // All the fine-grained style controls live behind one button instead of each being
            // its own toolbar item — with Font/Background/Auto/Auto font all inline, this bar
            // overflowed past a handful of items and the rest silently landed in the hidden
            // ">>" menu, which is why the Background picker (and friends) seemed to vanish.
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .help("Recalculate this image: re-read it, match the font, colours and sizes again, and drop any manual overrides (⌘R)")
                .accessibilityLabel("Recalculate")
                .keyboardShortcut("r", modifiers: .command)
                .disabled(scanning)
            Button { showStylePopover = true } label: { Image(systemName: "paintpalette") }
                .help("Overlay style").accessibilityLabel("Overlay style")
                .popover(isPresented: $showStylePopover, arrowEdge: .bottom) {
                    let bgBinding = Binding<Color>(get: { bg }, set: { style.bgHex = $0.hexString })
                    // Grouped into labelled sections rather than one flat stack of controls —
                    // it had grown to two color pickers, three auto-match toggles and a whole
                    // font row with no hierarchy to read it by.
                    VStack(alignment: .leading, spacing: 14) {
                        if style.mode == "text" {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Color")
                                HStack {
                                    ColorPicker("Text", selection: txtBinding, supportsOpacity: false)
                                    ColorPicker("Background", selection: bgBinding, supportsOpacity: false)
                                }
                                Toggle("Match text color from image", isOn: $style.autoTextColor)
                                    .help("Pick up the text's own ink color from the image and use it for the redrawn word; the Text color above is the fallback")
                                Toggle("Match background from image", isOn: $style.autoBg)
                                    .help("Pick up the color immediately around each match and use it as its background; the Background color above is the fallback")
                            }
                            Divider()
                            fontSection
                            Divider()
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Preview")
                                stylePreview(box: box, text: txt, background: bg)
                            }
                            imageScopeFooter
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("Box")
                                ColorPicker("Color", selection: boxBinding, supportsOpacity: false)
                                HStack {
                                    Text("Fill")
                                    Slider(value: $style.opacity, in: 0...0.8)
                                    Text("\(Int(style.opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                                }
                                Toggle("Outline", isOn: $style.outline)
                            }
                            imageScopeFooter
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
        .task(id: "\(path)#\(reloadToken)") {
            style = OverlayStyle.forImage(path)
            image = NSImage(contentsOfFile: path)
            failed = image == nil
            bgColors = []; inkSamples = []; matchedFonts = []; fontSizes = []; trackings = []; renderedFontNames = []
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
            if style.mode == "text" { await detectFonts() }
            await recomputeFontSizes()
            recomputeRenderedFontNames()
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
                recomputeRenderedFontNames()
                rebuildOverlay()
            }
        }
        .onChange(of: style.design) { _ in Task { await recomputeFontSizes(); rebuildOverlay() } }
        .onChange(of: style.weight) { _ in Task { await recomputeFontSizes(); recomputeRenderedFontNames(); rebuildOverlay() } }
        .onChange(of: style.kerning) { _ in recomputeTrackings(); rebuildOverlay() }
        .onChange(of: style.manualSize) { _ in recomputeTrackings(); rebuildOverlay() }
        .onChange(of: style.manualFont) { _ in
            applyFontOverride()
            Task { await recomputeFontSizes(); recomputeRenderedFontNames(); rebuildOverlay() }
        }
    }

    /// Spells out that these controls affect this image only, and offers the two ways out of
    /// that: back to the defaults, or make this image's look the new default.
    private var imageScopeFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("These settings apply to \((path as NSString).lastPathComponent) only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reset to defaults") {
                    OverlayStyle.clear(path)
                    style = OverlayStyle.current()
                }
                .font(.caption).buttonStyle(.link)
                .help("Forget this image's settings and go back to the defaults from Settings")
                Spacer()
                Button("Save as default") { style.saveAsDefaults() }
                    .font(.caption).buttonStyle(.link)
                    .help("Use this look as the starting point for images that have no settings of their own")
            }
        }
    }

    private static let zoomStep: CGFloat = 1.25
    private static let zoomRange: ClosedRange<CGFloat> = 0.02...16

    /// Re-reads the image and works every automatic setting out again, discarding the manual
    /// ones. Everything an estimate can produce — the matches, each one's colours and ink extent,
    /// the font matched to the page, the fitted sizes — comes back from the file rather than from
    /// anything remembered, which is what makes this the thing to reach for when an image has
    /// changed on disk or a previous scan went wrong.
    ///
    /// Mode and the overlay switch survive: those are how you are looking at the image, not
    /// estimates about it.
    private func refresh() {
        style.manualFont = ""; style.autoFont = true
        style.manualSize = 0; style.manualTracking = nil; style.kerning = true
        style.weight = "regular"; style.italic = false
        style.autoTextColor = true; style.autoBg = true
        reloadToken += 1
    }

    private func zoomIn()   { zoom = min((zoom ?? displayScale) * Self.zoomStep, Self.zoomRange.upperBound) }
    private func zoomOut()  { zoom = max((zoom ?? displayScale) / Self.zoomStep, Self.zoomRange.lowerBound) }

    /// Nothing about the drawing depends on the window any more — sizes, padding and outlines are
    /// all in the image's own pixels — so this is simply the image's style.
    private var drawingStyle: OverlayStyle { style }

    /// Everything the shared overlay drawing needs, from what this window has already computed —
    /// no second OCR pass, and guaranteed to be the same inputs the on-screen layer was built
    /// from, so a Save writes exactly what is being looked at.
    private func currentPlan() -> RenderPlan {
        RenderPlan(pixelSize: pixelSize, imageScale: imageScale, matches: style.show ? matches : [],
                   bgColors: bgColors, ink: inkSamples, matchedFonts: matchedFonts,
                   fontSizes: fontSizes, trackings: trackings)
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

    /// The Font section of the style popover: which family, how big, how tightly spaced,
    /// and the weight and slant. Pulled out of the popover's body because that body had grown
    /// past what the type-checker would infer in reasonable time -- and because this is the
    /// part of the panel with real logic in it, so it reads better on its own.
    @ViewBuilder private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
                    // Laid out like an ordinary text-editing toolbar (font, point size,
                    // then Bold/Italic toggles) rather than a settings-style option list.
                    // Picking a font or typing a size overrides whatever auto-match/fit
                    // found (and turns auto-match on, if it was off, so the change takes
                    // visible effect immediately); "Auto" in the font menu, or the Reset
                    // button once anything is overridden, goes back to automatic.
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
                        // Derived from manualSize rather than stored beside it: a second
                        // flag could disagree with the number it describes, which is
                        // exactly what went wrong with the font toggle.
                        Toggle("Fit size to the text in the image", isOn: Binding(
                            get: { style.manualSize == 0 },
                            set: { on in style.manualSize = on ? 0 : autoSizeShown }))
                            .help("Size each match to the glyphs measured on the image. Typing a size below turns this off.")
                        HStack(spacing: 8) {
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
                            .labelsHidden().frame(width: 148)

                            TextField("", value: sizeBinding, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 38)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: sizeBinding, in: 1...400).labelsHidden()
                            Text("pt").font(.caption).foregroundStyle(.secondary)
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
                        Toggle("Fit spacing to the text in the image", isOn: Binding(
                            get: { style.manualTracking == nil },
                            set: { on in style.manualTracking = on ? nil : fittedTracking }))
                            .help("Space the letters so the redrawn word spans the same width as the original. Typing a value below turns this off.")
                        HStack(spacing: 8) {
                            Text("Spacing").font(.caption).foregroundStyle(.secondary)
                            TextField("", value: trackingBinding, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 46)
                                .multilineTextAlignment(.trailing)
                            Stepper("", value: trackingBinding, in: -20...20, step: 0.1).labelsHidden()
                            Text("pt").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Kerning", isOn: $style.kerning)
                                .help("Use the font's own pair kerning. Off spaces every pair evenly.")
                        }
                        HStack(spacing: 6) {
                            Toggle(isOn: Binding(get: { style.weight == "bold" }, set: { style.weight = $0 ? "bold" : "regular" })) {
                                Text("B").bold()
                            }.toggleStyle(.button).help("Bold").accessibilityLabel("Bold")
                            Toggle(isOn: $style.italic) {
                                Text("I").italic()
                            }.toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
                            Spacer()
                            if !style.manualFont.isEmpty || style.manualSize > 0
                                || style.manualTracking != nil || !style.kerning
                                || style.weight == "bold" || style.italic {
                                Button("Reset to auto") {
                                    style.manualFont = ""; style.autoFont = true
                                    style.manualSize = 0; style.manualTracking = nil
                                    style.kerning = true
                                    style.weight = "regular"; style.italic = false
                                }
                                .font(.caption).buttonStyle(.link)
                                .help("Back to auto-matched font/size, regular style.weight, no style.italic")
                            }
                        }
                    }
        }
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
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .textSelection(.enabled)
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
            MatchView(text: sample, size: size, mode: style.mode,
                      box: box, textColor: textColor, opacity: style.opacity, outline: style.outline,
                      design: style.design, weight: style.weight,
                      sampled: bgColors.indices.contains(i) ? bgColors[i] : nil, background: background,
                      autoBackground: style.autoBg,
                      matchedFont: matchedFonts.indices.contains(i) ? matchedFonts[i] : nil,
                      // Image pixels clamped to the swatch, same reason as in Settings.
                      fontSize: min(imageFontSize(i), size.height * 0.8),
                      renderedFontName: renderedFontNames.indices.contains(i) ? renderedFontNames[i] : nil,
                      sampledTextColor: inkSamples.indices.contains(i) ? inkSamples[i]?.color : nil,
                      autoTextColor: style.autoTextColor, italic: style.italic)
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

    /// The family actually rendered: `style.manualFont` when the user has picked one from the style
    /// popover's Font picker, otherwise whatever detectFonts() found. Re-run whenever either
    /// changes, without re-scanning the image (detectFonts already did the expensive part).
    private func applyFontOverride() {
        // A font the user picked wins. Otherwise the detected one, but only while "Match font
        // from image" is on — with it off and nothing picked there is no family at all, which is
        // what tells the renderer to fall back to the Font and Weight from Settings.
        let effective = !style.manualFont.isEmpty ? style.manualFont
            : (style.autoFont ? detectedFontName : nil)
        matchedFonts = Array(repeating: effective, count: matches.count)
    }

    /// Cheap per-frame conversion of a match's cached native-pixel-scale font size (fontSizes,
    /// see recomputeFontSizes) to on-screen points — a single multiply, safe to call on every
    /// hover-move or resize instead of re-fitting from scratch. `style.manualSize`, when set, is
    /// already in on-screen points (that's what the toolbar's Size field shows and edits), so it
    /// bypasses the native-pixel cache and scale multiply entirely — every match gets exactly
    /// that point size, the same way setting a size in any text editor applies to the whole
    /// selection rather than scaling each run individually.
    /// A match's drawn size, in image pixels — what the renderer will actually use.
    /// A match's drawn size in points — the unit shown and typed. The renderer multiplies by the
    /// image's own pixels-per-point to get what it draws.
    private func imageFontSize(_ i: Int) -> CGFloat {
        if style.manualSize > 0 { return style.manualSize }
        return (fontSizes.indices.contains(i) ? fontSizes[i] : 12) / imageScale
    }

    /// Fits each match's font size once, at the image's native pixel scale rather than the
    /// current window size, so it only needs recomputing when the matches, matched fonts,
    /// style.design or style.weight actually change — never on hover or window resize (the view just scales
    /// the cached result at render time via `displayFontSize(_:scale:)`).
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
                    return inkFittedFontSize(for: it.text, weight: HL.fontWeight(w), design: HL.fontDesign(d),
                                             matchedFamily: family,
                                             fitting: CGSize(width: measured.rect.width * px.width,
                                                             height: measured.rect.height * px.height))
                }
                let box = CGSize(width: it.rect.width * px.width, height: it.rect.height * px.height)
                return effectiveFontSize(for: it.text, weight: HL.fontWeight(w), design: HL.fontDesign(d),
                                         matchedFamily: family, fitting: box)
            }
        }.value
        recomputeTrackings()
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
            let font = matchFont(size: size, weight: HL.fontWeight(style.weight),
                                 design: HL.fontDesign(style.design),
                                 matchedFamily: matchedFonts[safe: i] ?? nil)
            return inkFittedTracking(for: m.text, font: font, kerning: style.kerning,
                                     inkWidth: measured.rect.width * pixelSize.width)
        }
    }

    /// Resolves each matched family to its exact renderable (PostScript) name once, instead of
    /// on every render — see renderableFontName.
    private func recomputeRenderedFontNames() {
        let bold = style.weight == "bold"
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
                // The folder being searched, and the only thing being searched: there is no index
                // behind this, so what is listed always comes from the folder shown here.
                Menu {
                    Button("Open folder…") { pick(dir: true) { m.open(folder: $0[0]) } }
                    if m.folder != nil {
                        Button("Reload", action: m.reload)
                            .help("Re-read the folder, picking up anything added or changed")
                        Divider()
                        Button("Reveal in Finder") {
                            if let f = m.folder { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                        }
                    }
                    Divider()
                    Button("Add files…") { pick(dir: false) { m.add(files: $0) } }
                } label: {
                    Label(m.folder?.lastPathComponent ?? "Choose folder…", systemImage: "folder")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(m.folder?.path ?? "Pick the folder of images to search")

                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                    Image(systemName: "gearshape")
                }.help("Settings (highlight color)").accessibilityLabel("Settings")
            }.padding(10)
            .onAppear { m.restoreFolder() }
            Divider()
            if m.results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text(m.folder == nil ? "No folder open"
                         : m.query.isEmpty ? "Ready to search \(m.folder!.lastPathComponent)"
                         : "No matches for “\(m.query)” in \(m.folder!.lastPathComponent)")
                        .font(.title3).foregroundStyle(.secondary)
                    if m.folder == nil {
                        Text("Choose a folder of screenshots to search the text inside them.")
                            .font(.callout).foregroundStyle(.tertiary)
                        Button("Open folder…") { pick(dir: true) { m.open(folder: $0[0]) } }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    } else if m.query.isEmpty {
                        Text("Type any text and press Return.")
                            .font(.callout).foregroundStyle(.tertiary)
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
                if let r = m.reading {
                    ProgressView(value: Double(r.done), total: Double(max(r.total, 1)))
                        .frame(width: 90).controlSize(.small)
                    Text("\(r.done)/\(r.total)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                } else if m.busy {
                    ProgressView().controlSize(.small)
                }
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

    /// Shows an open panel modelessly, on the next turn of the run loop.
    ///
    /// Not runModal(): these are invoked from a Menu item, and starting a nested modal run loop
    /// while AppKit is still unwinding the menu's own tracking loop hangs the app — no crash
    /// report, because nothing crashes; the window simply stops responding. It only started
    /// happening when these moved from plain toolbar buttons into the folder menu.
    private func pick(dir: Bool, _ done: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async {
            let p = Panels.openPanel(dir: dir)
            guard !p.isVisible else { return }   // one at a time; it is a shared panel now
            p.begin { response in
                guard response == .OK, !p.urls.isEmpty else { return }
                done(p.urls)
            }
        }
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
