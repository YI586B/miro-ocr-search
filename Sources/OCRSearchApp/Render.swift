import AppKit
import SwiftUI
import OCRSearchCore

// MARK: - drawing constants

/// Breathing room around each match, as a fraction of that match's height, split evenly on both
/// sides. A fraction rather than a fixed number of points: the overlay is drawn into the image at
/// the image's own resolution, so anything expressed in on-screen points would mean a different
/// thing at every zoom level and window size — and did, until it was measured.
let matchBoxPaddingFraction: CGFloat = 0.3

/// Box-mode outline, likewise as a fraction of the match's height.
let boxOutlineFraction: CGFloat = 0.12

// MARK: - colour plumbing

/// sRGB CGColor from a `#RRGGBB` string, for drawing into the sRGB export context.
private func cgColor(hex: String, fallback: NSColor) -> CGColor {
    guard let c = Color(hex: hex) else { return fallback.cgColor }
    return cgColor(c)
}

/// A SwiftUI Color (as produced by the samplers, always built as explicit `.sRGB` with correct
/// components) as a CGColor in the same space the export context uses. Round-tripping through
/// NSColor here is safe precisely because the Color already carries an sRGB tag — unlike the
/// samplers' own raw NSBitmapImageRep reads, where converting the (mis-tagged) result would
/// apply a bogus gamma remap; see sampledBackgroundColors' note.
private func cgColor(_ c: Color) -> CGColor {
    (NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)).cgColor
}

// MARK: - the render

/// Everything drawn on one image, resolved once. Separated from the drawing itself so the
/// expensive part (OCR, colour sampling, font matching) can run on a background task and be
/// reused — the preview window has already computed all of this for the image it's showing.
struct RenderPlan: Sendable {
    var pixelSize: CGSize
    /// Pixels per point for this image; see imagePointScale. A manual size is in points, so this
    /// is what turns it into the pixels actually drawn.
    var imageScale: CGFloat = 1
    var matches: [TextMatch]
    var bgColors: [Color?]
    /// The original glyphs measured off the image: colour, and the box they occupy. What the
    /// overlay's size and position are derived from — see inkFittedFontSize.
    var ink: [InkSample?]
    var matchedFonts: [String?]
    var fontSizes: [CGFloat]
    /// Letter spacing fitted per match so the drawn width matches the measured ink width.
    var trackings: [CGFloat]
    /// Blur fitted per match so the redrawn text is as soft as the text it covers.
    var smoothness: [CGFloat] = []

    /// Every stage at once, as an export needs it: find the matches, sample each one's background
    /// and ink colour, auto-match a font family across the whole page, then fit a size, spacing
    /// and softness per match — all in the image's own pixel units. PreviewModel runs the same
    /// stages as the preview window loads an image and its style changes.
    static func build(path: String, query: String, searchMode: SearchMode, style: OverlayStyle) -> RenderPlan {
        let px = imagePixelSize(at: path) ?? .zero
        let pointScale = imagePointScale(at: path)
        let matches = style.show ? PlanStage.find(path: path, query: query, searchMode: searchMode) : []
        guard !matches.isEmpty, px.width > 0, px.height > 0 else {
            return RenderPlan(pixelSize: px, imageScale: pointScale, matches: [], bgColors: [], ink: [],
                              matchedFonts: [], fontSizes: [], trackings: [])
        }
        let (bg, ink) = style.showText ? PlanStage.sample(path: path, matches: matches) : ([], [])
        let family = PlanStage.family(for: style) { PlanStage.detectFont(path: path, pixelSize: px) }
        let sizes = PlanStage.fitSizes(matches: matches, ink: ink, family: family, style: style, pixelSize: px)
        let tracks = PlanStage.fitTrackings(matches: matches, ink: ink, sizes: sizes, family: family,
                                            style: style, pixelSize: px, imageScale: pointScale)
        let smooth = PlanStage.fitSmoothness(ink: ink, count: matches.count)
        return RenderPlan(pixelSize: px, imageScale: pointScale, matches: matches, bgColors: bg, ink: ink,
                          matchedFonts: Array(repeating: family, count: matches.count),
                          fontSizes: sizes, trackings: tracks, smoothness: smooth)
    }
}

/// The steps a RenderPlan is built from, in order. RenderPlan.build runs them all at once for an
/// export; PreviewModel runs them as the preview window loads, and again from the first step a
/// style change affects. One copy of each, so what the window shows and what an export writes
/// cannot drift apart.
enum PlanStage {
    /// The search's matches on the image; none when the query has no terms left.
    static func find(path: String, query: String, searchMode: SearchMode) -> [TextMatch] {
        let terms = searchTerms(query, mode: searchMode)
        guard !terms.isEmpty else { return [] }
        return (try? findMatches(at: URL(fileURLWithPath: path), terms: terms)) ?? []
    }

    /// Each match's surrounding background colour, and its glyphs' colour and extent.
    static func sample(path: String, matches: [TextMatch]) -> (bg: [Color?], ink: [InkSample?]) {
        let rects = matches.map(\.rect)
        return (sampledBackgroundColors(at: path, rects: rects), sampledInk(at: path, rects: rects))
    }

    /// Auto-matches the whole image's text to one closest-looking installed font at once (see
    /// bestMatchingFont(forImage:)), rather than judging each match independently — a screenshot
    /// is essentially always set in a single consistent font throughout, and scoring across many
    /// data points instead of one string at a time is what makes the system-font check reliable.
    /// Scores against *every* line on the page (allTextBoxes), not just the matches — those are
    /// filtered down to whatever the search happened to find, which for a specific search term
    /// can be a single short phrase, too few data points for aggregation to do any good (this
    /// was confirmed to be exactly why "New Relic" alone landed on the wrong font: with only that
    /// one string to score, it's back to the same single-string-coincidence problem aggregation
    /// was meant to fix). The overlay still only highlights the matches — this only changes what
    /// font detection itself is scored against.
    static func detectFont(path: String, pixelSize: CGSize) -> String? {
        let all = ((try? allTextBoxes(at: URL(fileURLWithPath: path))) ?? []).map { (text: $0.text, rect: $0.rect) }
        return bestMatchingFont(forImage: all, pixelSize: pixelSize, from: candidateFontFamilies())
    }

    /// The family drawn: a picked one wins; otherwise the detected one, but only while matching
    /// is on. nil means the style's design and weight. `detected` is only called when needed.
    static func family(for style: OverlayStyle, detected: () -> String?) -> String? {
        if !style.manualFont.isEmpty { return style.manualFont }
        return style.autoFont ? detected() : nil
    }

    static func fitSizes(matches: [TextMatch], ink: [InkSample?], family: String?,
                         style: OverlayStyle, pixelSize px: CGSize) -> [CGFloat] {
        matches.enumerated().map { i, m -> CGFloat in
            let w = style.weight.font, d = style.design.font
            // Fit to the ink measured off the image when there is any. Vision's box is the
            // fallback for a match whose glyphs could not be isolated — a blank box, or text on
            // a busy background — where an approximate size beats none.
            if let measured = ink[safe: i] ?? nil, measured.rect.height * px.height > 1 {
                return inkFittedFontSize(for: m.text, weight: w, design: d, matchedFamily: family,
                                         fitting: CGSize(width: measured.rect.width * px.width,
                                                         height: measured.rect.height * px.height))
            }
            let box = CGSize(width: m.rect.width * px.width, height: m.rect.height * px.height)
            return effectiveFontSize(for: m.text, weight: w, design: d, matchedFamily: family,
                                     fitting: box)
        }
    }

    /// Spacing is fitted after the sizes, because it depends on the font at its final size.
    static func fitTrackings(matches: [TextMatch], ink: [InkSample?], sizes: [CGFloat], family: String?,
                             style: OverlayStyle, pixelSize px: CGSize, imageScale: CGFloat) -> [CGFloat] {
        matches.enumerated().map { i, m -> CGFloat in
            guard let measured = ink[safe: i] ?? nil else { return 0 }
            let size = style.manualSize > 0 ? CGFloat(style.manualSize) * imageScale : (sizes[safe: i] ?? 12)
            let font = matchFont(size: size, weight: style.weight.font,
                                 design: style.design.font, matchedFamily: family)
            return inkFittedTracking(for: m.text, font: font, kerning: style.kerning,
                                     inkWidth: measured.rect.width * px.width)
        }
    }

    /// Softness comes straight from what was measured on the image, so it needs no font.
    static func fitSmoothness(ink: [InkSample?], count: Int) -> [CGFloat] {
        (0..<count).map { i in smoothnessToMatch(originalRise: (ink[safe: i] ?? nil)?.edgeRise ?? 0) }
    }
}

/// Composites `path` the way the preview window shows it — original image, match overlays,
/// watermark — at the image's own pixel resolution, and returns it as PNG data.
///
/// Rendering at native resolution rather than rasterising the on-screen SwiftUI view is the whole
/// point: the preview draws the image scaled down to fit a window, so capturing *that* and saving
/// it would bake in the downscale and then have to stretch it back up, which is what makes
/// exported overlay text look soft and unevenly spaced. Here the image is drawn 1:1 and the text
/// is re-laid-out at the font size that fits the match's box in real pixels, so every glyph is
/// rasterised once, at final size. See `configureTextQuality` for the rest.
///
/// PNG rather than the source's own format, always: the overlay is hard-edged text over flat
/// colour, exactly the content JPEG's chroma subsampling and ringing artefacts destroy. A
/// re-encoded JPEG would put a visible halo around every redrawn word.
func renderExportPNG(path: String, query: String, searchMode: SearchMode,
                     style: OverlayStyle, plan: RenderPlan? = nil) -> Data? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return nil }
    let plan = plan ?? RenderPlan.build(path: path, query: query, searchMode: searchMode, style: style)

    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    configureTextQuality(ctx)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawOverlay(in: ctx, canvas: CGSize(width: w, height: h), plan: plan, style: style)
    // Only when the overlay is on — with it off the export is the image as it is, and a watermark
    // would be the one thing contradicting that — and only while the switch is on.
    if style.show, Watermark.isOn { drawWatermark(ctx: ctx, width: CGFloat(w), height: CGFloat(h)) }
    NSGraphicsContext.restoreGraphicsState()
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
}

/// Draws every match's overlay — replacement text over a patch, a box, or both — onto `ctx`, whose canvas
/// is `canvas` pixels for an image whose native size is `plan.pixelSize`.
///
/// Shared by the export and by the preview window, which shows the result of this as a single
/// layer rather than assembling the overlay out of SwiftUI views. There used to be two
/// implementations of this drawing, one per surface, and they could not both be aligned to the
/// ink; now what is on screen is the same bitmap an export writes.
func drawOverlay(in ctx: CGContext, canvas: CGSize, plan: RenderPlan, style: OverlayStyle) {
    guard plan.pixelSize.width > 0, plan.pixelSize.height > 0 else { return }
    configureTextQuality(ctx)
    // Canvas pixels per native image pixel: 1 for an export, and also 1 for the preview, which
    // draws this layer at native size and lets the view scale it down alongside the photo.
    let k = canvas.width / plan.pixelSize.width

    let w = canvas.width, h = canvas.height

    for (i, m) in plan.matches.enumerated() {
        // Vision's rects are normalised with a bottom-left origin, which is also CGContext's —
        // no flip needed, unlike the samplers reading top-down bitmap rows.
        let boxRect = CGRect(x: m.rect.minX * w, y: m.rect.minY * h,
                             width: m.rect.width * w, height: m.rect.height * h)
        // Breathing room proportional to the text itself, in image pixels. Everything the
        // overlay draws is now measured in the image's own units — nothing is derived from how
        // big the window happens to be showing it, so zooming changes what you can see and never
        // what is drawn.
        let pad = boxRect.height * matchBoxPaddingFraction
        let padded = boxRect.insetBy(dx: -pad / 2, dy: -pad / 2)

        // Text first, then the box: with both on, the box highlights the redrawn word.
        if style.showText {
            let fill = (style.autoBg ? plan.bgColors[safe: i] ?? nil : nil)
                .map(cgColor) ?? cgColor(hex: style.bgHex, fallback: .white)
            // Snapped to whole pixels: the patch is a flat rectangle whose only job is to cover
            // the original word, and a fractional edge would leave a half-lit row of the old text
            // showing through as a faint line.
            ctx.setFillColor(fill)
            ctx.fill(padded.integral)

            let measured = plan.ink[safe: i] ?? nil
            let inkColor = (style.autoTextColor ? measured?.color : nil)
                .map(cgColor) ?? cgColor(hex: style.textHex, fallback: .black)
            let inkRect = measured.map {
                CGRect(x: $0.rect.minX * w, y: $0.rect.minY * h,
                       width: $0.rect.width * w, height: $0.rect.height * h)
            }
            let size = (style.manualSize > 0 ? CGFloat(style.manualSize) * plan.imageScale
                                             : (plan.fontSizes[safe: i] ?? 12)) * k
            let tracking = style.manualTracking.map { CGFloat($0) * plan.imageScale }
                ?? (plan.trackings[safe: i] ?? 0) * k
            let blur = style.manualSmoothness.map { CGFloat($0) * plan.imageScale }
                ?? (plan.smoothness[safe: i] ?? 0) * k
            drawMatchText(m.text, ink: inkRect, box: boxRect, size: size, color: inkColor,
                          family: plan.matchedFonts[safe: i] ?? nil, tracking: tracking,
                          blur: blur, style: style, ctx: ctx)
        }
        if style.showBoxes {
            let box = cgColor(hex: style.boxHex, fallback: .systemYellow)
            ctx.setFillColor(box.copy(alpha: CGFloat(style.opacity)) ?? box)
            ctx.fill(padded)
            if style.outline {
                ctx.setStrokeColor(box)
                ctx.setLineWidth(max(1, boxRect.height * boxOutlineFraction))
                ctx.stroke(padded)
            }
        }
    }
}

/// The overlay on its own, over transparency, at the image's native resolution — what the preview
/// window lays over the photo. Same drawing as an export, so the two cannot drift apart.
func overlayLayerImage(plan: RenderPlan, style: OverlayStyle) -> NSImage? {
    let w = Int(plan.pixelSize.width), h = Int(plan.pixelSize.height)
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawOverlay(in: ctx, canvas: CGSize(width: w, height: h), plan: plan, style: style)
    NSGraphicsContext.restoreGraphicsState()
    guard let img = ctx.makeImage() else { return nil }
    return NSImage(cgImage: img, size: NSSize(width: w, height: h))
}

/// The settings that decide whether exported text reads as crisp or as subtly uneven — the
/// "jittery" look. Three separate things are going on, and only the first is obvious:
///
/// 1. **Subpixel quantisation off.** By default Core Graphics snaps each glyph's origin to a
///    fraction of a pixel (typically a quarter) before rasterising. On screen that is a cache
///    optimisation nobody notices; baked into a still image it means the gap between letters
///    rounds differently for each pair, so a word's spacing visibly stutters. This is the single
///    biggest cause of the effect.
/// 2. **Subpixel positioning on.** The other half of the same coin: glyphs are allowed to sit at
///    true fractional offsets, so accumulated advance widths stay exact across a long word
///    instead of drifting by up to half a pixel per glyph.
/// 3. **Font smoothing off, antialiasing on.** "Smoothing" is LCD/subpixel antialiasing, which
///    lights individual red/green/blue elements and is tuned for one specific panel's layout.
///    In a file it shows up as coloured fringing on every stem — obvious once the image is
///    viewed on a different display, scaled, or placed on a Miro board. Plain greyscale
///    antialiasing is what a rendered image wants.
func configureTextQuality(_ ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSubpixelQuantizeFonts(false)
    ctx.setAllowsFontSubpixelQuantization(false)
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSmoothFonts(false)
    ctx.setAllowsFontSmoothing(false)
}

/// Draws one match's replacement text so its glyphs land on `ink` — the box the original glyphs
/// were measured to occupy in the image (see sampledInk). Left edge to left edge, lowest ink to
/// lowest ink.
///
/// Aligning ink to ink is the whole point. The previous version centred the font's cap height
/// inside Vision's bounding box, which got two things wrong at once: Vision's box is taller than
/// the ink it contains, so the text came out 7-11% too big, and centring a cap height ignores
/// descenders, so anything with a 'y' or 'g' in it sat several pixels low. Both disappear when
/// the target is the ink itself. `box` is only the fallback for a match whose glyphs could not be
/// isolated from their background.
///
/// Drawn through CTLine rather than NSAttributedString.draw(at:), because draw(at:) positions the
/// line box and the whole point here is to position the baseline.
private func drawMatchText(_ text: String, ink: CGRect?, box: CGRect, size: CGFloat, color: CGColor,
                           family: String?, tracking: CGFloat, blur: CGFloat,
                           style: OverlayStyle, ctx: CGContext) {
    var font = matchFont(size: size, weight: style.weight.font,
                         design: style.design.font, matchedFamily: family)
    var shear: CGFloat = 0
    if style.italic {
        let real = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if real.fontDescriptor.symbolicTraits.contains(.italic) { font = real }
        // No real italic member in this family: slant it in the context instead, which is the
        // same synthetic oblique SwiftUI's .italic() falls back to, so preview and export agree.
        else { shear = 0.2 }
    }

    var attrs = overlayAttributes(font: font, tracking: tracking, kerning: style.kerning)
    attrs[.foregroundColor] = NSColor(cgColor: color) ?? .black
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let origin: CGPoint
    if let ink, ink.height > 1 {
        origin = inkDrawOrigin(for: text, font: font, tracking: tracking, kerning: style.kerning, ink: ink)
    } else {
        origin = CGPoint(x: box.minX, y: box.minY + (box.height - font.capHeight) / 2)
    }

    // Drawn into a scratch layer first when it has to be softened, since a blur needs pixels
    // around the glyphs to spread into and must not touch the patch underneath.
    if blur > 0.05, let softened = blurredText(line: line, origin: origin, shear: shear, blur: blur) {
        ctx.draw(softened.image, in: softened.rect)
        return
    }
    ctx.saveGState()
    if shear != 0 {
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0))
        ctx.textPosition = .zero
    } else {
        ctx.textPosition = origin
    }
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

/// The line rendered on its own and Gaussian-blurred, ready to composite where it belongs.
///
/// The margin is generous on purpose: a Gaussian does not stop at three sigma, and clipping its
/// tail leaves a visible straight edge where the softness is cut off.
private func blurredText(line: CTLine, origin: CGPoint, shear: CGFloat,
                         blur: CGFloat) -> (image: CGImage, rect: CGRect)? {
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let margin = ceil(blur * 4) + 2
    let w = Int(ceil(bounds.width + shear * bounds.height + margin * 2))
    let h = Int(ceil(bounds.height + margin * 2))
    guard w > 0, h > 0, w < 8000, h < 8000,
          let scratch = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    configureTextQuality(scratch)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: scratch, flipped: false)
    scratch.saveGState()
    scratch.translateBy(x: margin - bounds.minX, y: margin - bounds.minY)
    if shear != 0 { scratch.concatenate(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0)) }
    scratch.textPosition = .zero
    CTLineDraw(line, scratch)
    scratch.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    guard let drawn = scratch.makeImage() else { return nil }
    let input = CIImage(cgImage: drawn)
    guard let filter = CIFilter(name: "CIGaussianBlur",
                                parameters: [kCIInputImageKey: input, kCIInputRadiusKey: blur]),
          let output = filter.outputImage,
          // clamped back to the scratch bounds: the filter's extent grows by the blur radius
          let blurred = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            .createCGImage(output, from: input.extent) else { return nil }
    let rect = CGRect(x: origin.x + bounds.minX - margin, y: origin.y + bounds.minY - margin,
                      width: CGFloat(w), height: CGFloat(h))
    return (blurred, rect)
}

/// The same bottom-right badge the preview stamps on every image, at the same pixel size and
/// offsets — see watermarkPixelSize — so the export matches what was on screen.
///
/// Built here rather than blitted from a file: the background is a translucent rectangle and the
/// wordmark is vector art rasterised straight into this context at its final size, which
/// is what keeps the badge's edges and letterforms clean on a full-resolution image instead of
/// upscaling a small bitmap.
private func drawWatermark(ctx: CGContext, width: CGFloat, height: CGFloat) {
    let ww = watermarkPixelSize.width, wh = watermarkPixelSize.height
    let rect = CGRect(x: width - watermarkRightMargin - ww, y: watermarkBottomMargin,
                      width: ww, height: wh)
    guard rect.minX > 0, rect.maxY < height else { return }   // image too small to carry the badge

    ctx.saveGState()
    ctx.setAlpha(watermarkOpacity)
    ctx.setFillColor(cgColor(watermarkBackground))
    ctx.fill(rect)
    ctx.restoreGState()

    // Centred on both axes: the SVG's box wraps the wordmark exactly, so centring the box centres
    // the letters.
    guard let art = watermarkWordmark, art.size.width > 0 else { return }
    let mw = ww * watermarkWordmarkWidthFraction
    let mh = mw * (art.size.height / art.size.width)
    art.draw(in: CGRect(x: rect.midX - mw / 2, y: rect.midY - mh / 2, width: mw, height: mh),
             from: .zero, operation: .sourceOver, fraction: watermarkOpacity)
}
