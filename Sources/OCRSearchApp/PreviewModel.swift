import SwiftUI
import AppKit
import OCRSearchCore

/// The preview window's scan of one image, and everything its overlay is built from, worked out
/// with the same PlanStage steps an export uses. The view keeps only what is about looking at the
/// image — zoom, hover, the style panel — and hands every style change to update(_:), which
/// re-runs just the stages that change affects.
///
/// Two things differ from an export on purpose. Colours and ink are sampled even while Text is
/// off, because the hover targets are the measured glyphs. And the font is detected whenever Text
/// is on, not only while matching is, so the font menu can say what "Auto" would pick.
@MainActor final class PreviewModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var failed = false
    @Published private(set) var scanning = false
    @Published private(set) var pixelSize: CGSize = .zero
    /// Pixels per point for this image; see imagePointScale. Sizes shown and typed are points.
    @Published private(set) var imageScale: CGFloat = 1
    @Published private(set) var matches: [TextMatch] = []
    @Published private(set) var bgColors: [Color?] = []
    /// The original glyphs measured off the image, per match — colour and extent. See sampledInk.
    @Published private(set) var ink: [InkSample?] = []
    /// What font detection found, kept apart from `family` so the font menu can show it as
    /// "Auto (X)" even while a font is picked by hand.
    @Published private(set) var detectedFont: String?
    /// The family drawn; see PlanStage.family.
    @Published private(set) var family: String?
    /// Fitted per match, in image pixels, once per change of font, design or weight — never on
    /// hover, zoom or window resize.
    @Published private(set) var fontSizes: [CGFloat] = []
    @Published private(set) var trackings: [CGFloat] = []
    @Published private(set) var smoothness: [CGFloat] = []
    /// The whole overlay, drawn by the same code that draws an export (overlayLayerImage) and
    /// laid over the photo, rather than assembled from a SwiftUI view per match. Two
    /// implementations of the same drawing could not both be aligned to the ink; this way the
    /// preview shows literally the bitmap that an export writes.
    @Published private(set) var overlayLayer: NSImage?

    private var path = ""
    /// The latest drawing style: the image's own, with the app-wide overlay, Boxes and Text
    /// switches applied.
    private var style = OverlayStyle()
    /// Whether detection has run for this image. Separate from detectedFont, which is also nil
    /// when detection ran and found nothing.
    private var detected = false
    /// What the current sizes and spacing were fitted for, so a change that does not affect them
    /// (a colour, the fill) only redraws.
    private var sizesFor: SizeInputs?
    private var trackingsFor: TrackingInputs?
    /// Bumped by each load and each fit, so a slow result that has been overtaken is dropped.
    private var loadGeneration = 0
    private var fitGeneration = 0

    private struct SizeInputs: Equatable {
        var family: String?, design: TextDesign, weight: TextWeight
    }
    private struct TrackingInputs: Equatable {
        var sizes: SizeInputs, manualSize: Double, kerning: Bool
    }

    /// Reads the image and runs every stage for it.
    func load(path: String, query: String, searchMode: SearchMode, style: OverlayStyle) async {
        loadGeneration += 1
        let gen = loadGeneration
        self.path = path
        self.style = style
        image = NSImage(contentsOfFile: path)
        failed = image == nil
        pixelSize = .zero; imageScale = 1
        matches = []; bgColors = []; ink = []
        detectedFont = nil; family = nil; detected = false
        fontSizes = []; trackings = []; smoothness = []; sizesFor = nil; trackingsFor = nil
        overlayLayer = nil
        guard image != nil else { return }

        scanning = true
        let scan = await Task.detached(priority: .userInitiated) {
            let matches = PlanStage.find(path: path, query: query, searchMode: searchMode)
            let (bg, ink) = PlanStage.sample(path: path, matches: matches)
            return (px: imagePixelSize(at: path) ?? .zero, scale: imagePointScale(at: path),
                    matches: matches, bg: bg, ink: ink)
        }.value
        guard gen == loadGeneration else { return }
        pixelSize = scan.px; imageScale = scan.scale
        matches = scan.matches; bgColors = scan.bg; ink = scan.ink
        smoothness = PlanStage.fitSmoothness(ink: ink, count: matches.count)
        // With the latest style, which may have changed while the scan ran.
        await update(self.style)
        if gen == loadGeneration { scanning = false }
    }

    /// Takes a new drawing style and brings the overlay up to date with it, re-running only the
    /// stages whose inputs changed.
    func update(_ style: OverlayStyle) async {
        self.style = style
        // Still scanning: load finishes with whatever the style is by then.
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let gen = loadGeneration

        if (style.showText || style.autoFont), !detected, !matches.isEmpty {
            detected = true
            let (p, px) = (path, pixelSize)
            let found = await Task.detached(priority: .userInitiated) {
                PlanStage.detectFont(path: p, pixelSize: px)
            }.value
            guard gen == loadGeneration else { return }
            detectedFont = found
        }

        let current = self.style
        let fam = PlanStage.family(for: current) { detectedFont }
        family = fam
        let sizeInputs = SizeInputs(family: fam, design: current.design, weight: current.weight)
        if sizeInputs != sizesFor {
            sizesFor = sizeInputs
            fitGeneration += 1
            let fit = fitGeneration
            let (m, k, px) = (matches, ink, pixelSize)
            let sizes = await Task.detached(priority: .userInitiated) {
                PlanStage.fitSizes(matches: m, ink: k, family: fam, style: current, pixelSize: px)
            }.value
            guard gen == loadGeneration, fit == fitGeneration else { return }
            fontSizes = sizes
            trackingsFor = nil
        }
        let latest = self.style
        let trackingInputs = TrackingInputs(sizes: sizeInputs, manualSize: latest.manualSize, kerning: latest.kerning)
        if trackingInputs != trackingsFor {
            trackingsFor = trackingInputs
            trackings = PlanStage.fitTrackings(matches: matches, ink: ink, sizes: fontSizes, family: fam,
                                               style: latest, pixelSize: pixelSize, imageScale: imageScale)
        }
        rebuildOverlay()
    }

    /// Everything the overlay drawing needs, from what has already been worked out — no second
    /// OCR pass, and the same inputs the on-screen layer was built from, so an export from the
    /// window writes exactly what is being looked at.
    var plan: RenderPlan {
        RenderPlan(pixelSize: pixelSize, imageScale: imageScale, matches: style.show ? matches : [],
                   bgColors: bgColors, ink: ink, matchedFonts: Array(repeating: family, count: matches.count),
                   fontSizes: fontSizes, trackings: trackings, smoothness: smoothness)
    }

    /// The style the overlay is drawn with.
    var drawingStyle: OverlayStyle { style }

    /// Redraws the overlay layer. Cheap next to the scan (no OCR, no pixel sampling), and drawn
    /// at the image's native resolution, so resizing or zooming the window never needs it.
    private func rebuildOverlay() {
        guard pixelSize.width > 0 else { overlayLayer = nil; return }
        overlayLayer = overlayLayerImage(plan: plan, style: style)
    }
}
