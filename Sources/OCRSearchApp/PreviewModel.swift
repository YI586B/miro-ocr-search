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
    /// What the matches on screen were found with. The window's search field can run ahead of
    /// this while a search is still going.
    @Published private(set) var query = ""
    @Published private(set) var searchMode: SearchMode = .phrase
    @Published private(set) var failed = false
    @Published private(set) var scanning = false
    @Published private(set) var pixelSize: CGSize = .zero
    /// Pixels per point for this image; see imagePointScale. Sizes shown and typed are points.
    @Published private(set) var imageScale: CGFloat = 1
    @Published private(set) var matches: [TextMatch] = []
    @Published private(set) var bgColors: [Color?] = []
    /// The original glyphs measured off the image, per match — colour and extent. See sampledInk.
    @Published private(set) var ink: [InkSample?] = []
    /// What font detection found for each match, from the block of text around it (see
    /// BlockFontDetector) — including whether a family is Noto Sans standing in for SF.
    @Published private(set) var detections: [DetectedFont?] = []
    /// Detection's answer for the first match: what the font menu offers as "Auto (X)" and the
    /// style panel names beside a picked font.
    var detection: DetectedFont? { detections.first ?? nil }
    var detectedFont: String? { detection?.family }
    /// The family each match is drawn in; see PlanStage.family.
    @Published private(set) var families: [String?] = []
    /// How much heavier each match's family is drawn; see PlanStage.weightBoost.
    @Published private(set) var weightBoosts: [CGFloat] = []
    /// Fitted per match, in image pixels, once per change of font, design or weight — never on
    /// hover, zoom or window resize.
    @Published private(set) var fontSizes: [CGFloat] = []
    @Published private(set) var trackings: [CGFloat] = []
    /// The weight each match is drawn in; see PlanStage.fitWeights.
    @Published private(set) var weights: [MatchWeight] = []
    /// Each match's original letters painted out; see cleanedPatches.
    private(set) var patches: [CleanedPatch?] = []
    @Published private(set) var smoothness: [CGFloat] = []
    /// Sharpening per match; see PlanStage.fitEdges.
    @Published private(set) var sharpness: [CGFloat] = []
    /// The whole overlay, drawn by the same code that draws an export (overlayLayerImage) and
    /// laid over the photo, rather than assembled from a SwiftUI view per match. Two
    /// implementations of the same drawing could not both be aligned to the ink; this way the
    /// preview shows literally the bitmap that an export writes.
    @Published private(set) var overlayLayer: NSImage?

    private var path = ""
    /// The recognised page, kept so a new search and font detection need no second OCR pass.
    private var page: RecognizedPage?
    /// Detects per block and remembers each block's answer for this image, across searches.
    private var detector: BlockFontDetector?
    /// The latest drawing style: the image's own, with the app-wide overlay, Boxes and Text
    /// switches applied.
    private var style = OverlayStyle()
    /// Whether detection has run for the current matches. Separate from `detections`, which hold
    /// nil where detection ran and found nothing.
    private var detected = false
    /// What the current sizes and spacing were fitted for, so a change that does not affect them
    /// (a colour, the fill) only redraws.
    private var sizesFor: SizeInputs?
    private var trackingsFor: TrackingInputs?
    /// Bumped by each load and each fit, so a slow result that has been overtaken is dropped.
    private var loadGeneration = 0
    private var fitGeneration = 0

    private struct SizeInputs: Equatable {
        var families: [String?], weightBoosts: [CGFloat], design: TextDesign, weight: TextWeight, autoWeight: Bool
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
        self.query = query
        self.searchMode = searchMode
        image = NSImage(contentsOfFile: path)
        failed = image == nil
        pixelSize = .zero; imageScale = 1
        matches = []; bgColors = []; ink = []; patches = []
        detections = []; families = []; weightBoosts = []; detected = false; page = nil; detector = nil
        fontSizes = []; trackings = []; weights = []; smoothness = []; sharpness = []; sizesFor = nil; trackingsFor = nil
        overlayLayer = nil
        guard image != nil else { return }

        scanning = true
        // Recognised whatever the query, so a search typed later in the window has a page to use.
        let scan = await Task.detached(priority: .userInitiated) {
            (page: try? RecognizedPage(at: URL(fileURLWithPath: path)),
             px: imagePixelSize(at: path) ?? .zero, scale: imagePointScale(at: path))
        }.value
        guard gen == loadGeneration else { return }
        pixelSize = scan.px; imageScale = scan.scale; page = scan.page
        detector = scan.page.map { BlockFontDetector(page: $0, path: path, pixelSize: scan.px) }
        await rematch(gen)
        if gen == loadGeneration { scanning = false }
    }

    /// Searches the image again for `query`, from the page already recognised: only the matching,
    /// sampling and fitting run again.
    func search(query: String, searchMode: SearchMode) async {
        guard query != self.query || searchMode != self.searchMode else { return }
        self.query = query
        self.searchMode = searchMode
        // Still loading: load finishes with whatever the query is by then.
        guard page != nil, pixelSize.width > 0 else { return }
        let gen = loadGeneration
        scanning = true
        await rematch(gen)
        if gen == loadGeneration, query == self.query, searchMode == self.searchMode { scanning = false }
    }

    /// Finds the current query's matches on the page, samples them, and refits the overlay.
    private func rematch(_ gen: Int) async {
        while true {
            let (q, m, p, recognised) = (query, searchMode, path, page)
            let found = await Task.detached(priority: .userInitiated) {
                let matches = recognised.map { PlanStage.find(page: $0, query: q, searchMode: m) } ?? []
                let (bg, ink, patches) = PlanStage.sample(path: p, matches: matches)
                return (matches: matches, bg: bg, ink: ink, patches: patches)
            }.value
            guard gen == loadGeneration else { return }
            // Typed again while that ran: search for the newer text instead.
            guard q == query, m == searchMode else { continue }
            matches = found.matches; bgColors = found.bg; ink = found.ink; patches = found.patches
            fontSizes = []; trackings = []; weights = []; sizesFor = nil; trackingsFor = nil
            // Detection is per match now, so new matches need their blocks looked up.
            detections = []; detected = false
            // With the latest style, which may have changed while this ran.
            await update(style)
            return
        }
    }

    /// Takes a new drawing style and brings the overlay up to date with it, re-running only the
    /// stages whose inputs changed.
    func update(_ style: OverlayStyle) async {
        self.style = style
        // Still scanning: load finishes with whatever the style is by then.
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let gen = loadGeneration

        if (style.showText || style.autoFont), !detected, !matches.isEmpty, let detector {
            detected = true
            let m = matches
            let found = await Task.detached(priority: .userInitiated) { detector.detect(m) }.value
            guard gen == loadGeneration, found.count == matches.count else { return }
            detections = found
        }

        let current = self.style
        let found = matches.indices.map { detections[safe: $0] ?? nil }
        let fam = found.map { d in PlanStage.family(for: current) { d?.family } }
        let boost = found.map { PlanStage.weightBoost(for: current, detected: $0) }
        families = fam
        weightBoosts = boost
        let sizeInputs = SizeInputs(families: fam, weightBoosts: boost, design: current.design, weight: current.weight,
                                    autoWeight: current.autoWeight)
        if sizeInputs != sizesFor {
            sizesFor = sizeInputs
            fitGeneration += 1
            let fit = fitGeneration
            let (m, k, px, p) = (matches, ink, pixelSize, path)
            // Weights first: the sizes are fitted in the weight each match is drawn in.
            let fitted = await Task.detached(priority: .userInitiated) {
                let weights = PlanStage.fitWeights(path: p, matches: m, ink: k, families: fam, weightBoosts: boost, style: current)
                let sizes = PlanStage.fitSizes(matches: m, ink: k, families: fam, weightBoosts: boost, weights: weights,
                                               style: current, pixelSize: px)
                return (weights: weights, sizes: sizes)
            }.value
            guard gen == loadGeneration, fit == fitGeneration else { return }
            weights = fitted.weights
            fontSizes = fitted.sizes
            trackingsFor = nil
        }
        let latest = self.style
        let trackingInputs = TrackingInputs(sizes: sizeInputs, manualSize: latest.manualSize, kerning: latest.kerning)
        if trackingInputs != trackingsFor {
            trackingsFor = trackingInputs
            trackings = PlanStage.fitTrackings(matches: matches, ink: ink, sizes: fontSizes, families: fam,
                                               weightBoosts: boost, weights: weights, style: latest, pixelSize: pixelSize, imageScale: imageScale)
            // Edges depend on the font at its final size, like spacing.
            let edges = PlanStage.fitEdges(matches: matches, ink: ink, sizes: fontSizes, families: fam,
                                           weightBoosts: boost, weights: weights, style: latest, imageScale: imageScale)
            smoothness = edges.blur; sharpness = edges.sharpen
        }
        rebuildOverlay()
    }

    /// Everything the overlay drawing needs, from what has already been worked out — no second
    /// OCR pass, and the same inputs the on-screen layer was built from, so an export from the
    /// window writes exactly what is being looked at.
    var plan: RenderPlan {
        RenderPlan(pixelSize: pixelSize, imageScale: imageScale, matches: style.show ? matches : [],
                   bgColors: bgColors, ink: ink, matchedFonts: matches.indices.map { families[safe: $0] ?? nil },
                   fontSizes: fontSizes, trackings: trackings, smoothness: smoothness, sharpness: sharpness,
                   weightBoosts: weightBoosts,
                   weights: weights, patches: patches)
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
