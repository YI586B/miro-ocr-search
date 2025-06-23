import AppKit
import SwiftUI
import OCRSearchCore

// MARK: - style snapshot

/// The persisted overlay look (the HL.* defaults), snapshotted into a plain value so a render can
/// run off the main actor without reading @AppStorage — which is a SwiftUI view-side wrapper and
/// isn't available to the export path, whether that runs from the preview window's Save command
/// or from a batch export with no preview window open at all.
struct OverlayStyle: Sendable {
    var show = true
    var mode = "box"
    var boxHex = HL.defaultBox
    var opacity = 0.35
    var outline = true
    var textHex = HL.defaultText
    var autoTextColor = true
    var bgHex = HL.defaultBg
    var autoBg = true
    var design = "default"
    var weight = "regular"
    var autoFont = false
    var manualFont = ""
    var manualSize: Double = 0
    var manualSizeScale: Double = 0
    var italic = false

    /// Reads whatever the Settings window and the preview toolbar have persisted. Every lookup
    /// goes through an explicit "is it set at all?" check rather than UserDefaults' zero/false
    /// defaults, so an untouched install exports with the same look it previews with instead of
    /// silently falling back to `false` for every toggle.
    static func current(_ d: UserDefaults = .standard) -> OverlayStyle {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        return OverlayStyle(
            show: bool(HL.show, true),
            mode: d.string(forKey: HL.mode) ?? "box",
            boxHex: d.string(forKey: HL.boxHex) ?? HL.defaultBox,
            opacity: double(HL.opacity, 0.35),
            outline: bool(HL.outline, true),
            textHex: d.string(forKey: HL.textHex) ?? HL.defaultText,
            autoTextColor: bool(HL.autoTextColor, true),
            bgHex: d.string(forKey: HL.bgHex) ?? HL.defaultBg,
            autoBg: bool(HL.autoBg, true),
            design: d.string(forKey: HL.design) ?? "default",
            weight: d.string(forKey: HL.weight) ?? "regular",
            autoFont: bool(HL.autoFont, false),
            manualFont: d.string(forKey: HL.manualFont) ?? "",
            manualSize: double(HL.manualSize, 0),
            manualSizeScale: double(HL.manualSizeScale, 0),
            italic: bool(HL.italic, false))
    }
}

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
    var matches: [TextMatch]
    var bgColors: [Color?]
    var textColors: [Color?]
    var matchedFonts: [String?]
    var fontSizes: [CGFloat]

    /// Does from scratch what PreviewView does incrementally as an image loads: find the matches,
    /// sample each one's background and ink colour, auto-match a font family across the whole
    /// page, then fit a size per match — all in the image's own pixel units.
    static func build(path: String, query: String, searchMode: SearchMode, style: OverlayStyle) -> RenderPlan {
        let px = imagePixelSize(at: path) ?? .zero
        let url = URL(fileURLWithPath: path)
        let terms = searchTerms(query, mode: searchMode)
        let matches = (style.show && !terms.isEmpty)
            ? ((try? findMatches(at: url, terms: terms)) ?? [])
            : []
        guard !matches.isEmpty, px.width > 0, px.height > 0 else {
            return RenderPlan(pixelSize: px, matches: [], bgColors: [], textColors: [],
                              matchedFonts: [], fontSizes: [])
        }
        let rects = matches.map(\.rect)
        let bg = style.mode == "text" ? sampledBackgroundColors(at: path, rects: rects) : []
        let ink = style.mode == "text" ? sampledTextColors(at: path, rects: rects) : []

        var family: String? = style.manualFont.isEmpty ? nil : style.manualFont
        if style.autoFont, family == nil {
            let all = ((try? allTextBoxes(at: url)) ?? []).map { (text: $0.text, rect: $0.rect) }
            family = bestMatchingFont(forImage: all, pixelSize: px, from: candidateFontFamilies())
        }
        let families = Array(repeating: family, count: matches.count)
        let sizes = matches.map { m -> CGFloat in
            let box = CGSize(width: m.rect.width * px.width, height: m.rect.height * px.height)
            return effectiveFontSize(for: m.text, weight: HL.fontWeight(style.weight),
                                     design: HL.fontDesign(style.design),
                                     matchedFamily: family, autoFont: style.autoFont, fitting: box)
        }
        return RenderPlan(pixelSize: px, matches: matches, bgColors: bg, textColors: ink,
                          matchedFonts: families, fontSizes: sizes)
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

    // Native pixels per on-screen point. Fixed geometry the preview expresses in points (the
    // match box padding, the outline width, a manually typed font size) has to be scaled by this
    // to land the same way at full resolution — 2pt of outline on an image shown at 40% is 5
    // pixels, not 2. See HL.manualSizeScale for where the recorded value comes from; when nothing
    // has recorded one (no preview window has ever been opened) a mid-sized window's worth of
    // scale is assumed.
    let haveScale = style.manualSizeScale > 0
    let scale: CGFloat = haveScale ? 1 / CGFloat(style.manualSizeScale) : max(1, CGFloat(w) / 900)
    let pad = matchBoxPadding * scale

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsCtx

    for (i, m) in plan.matches.enumerated() {
        // Vision's rects are normalised with a bottom-left origin, which is also CGContext's —
        // no flip needed, unlike the samplers reading top-down bitmap rows.
        let boxRect = CGRect(x: m.rect.minX * CGFloat(w), y: m.rect.minY * CGFloat(h),
                             width: m.rect.width * CGFloat(w), height: m.rect.height * CGFloat(h))
        let padded = boxRect.insetBy(dx: -pad / 2, dy: -pad / 2)

        if style.mode == "text" {
            let fill = (style.autoBg ? plan.bgColors[safe: i] ?? nil : nil)
                .map(cgColor) ?? cgColor(hex: style.bgHex, fallback: .white)
            // Snapped to whole pixels: the patch is a flat rectangle whose only job is to cover
            // the original word, and a fractional edge would leave a half-lit row of the old text
            // showing through as a faint line.
            ctx.setFillColor(fill)
            ctx.fill(padded.integral)

            let ink = (style.autoTextColor ? plan.textColors[safe: i] ?? nil : nil)
                .map(cgColor) ?? cgColor(hex: style.textHex, fallback: .black)
            // A manual size is only honoured when the scale it is relative to is actually
            // known. Guessing it is fine for a couple of pixels of padding, but a font size
            // guessed 30% wrong is text spilling out of its own background patch, so without a
            // recorded scale the fitted size wins — which is what the field shows as its
            // placeholder anyway until the user overrides it.
            let size = (style.manualSize > 0 && haveScale)
                ? CGFloat(style.manualSize) * scale
                : (plan.fontSizes[safe: i] ?? 12)
            drawMatchText(m.text, in: boxRect, size: size, ink: ink,
                          family: plan.matchedFonts[safe: i] ?? nil, style: style, ctx: ctx)
        } else {
            let box = cgColor(hex: style.boxHex, fallback: .systemYellow)
            ctx.setFillColor(box.copy(alpha: CGFloat(style.opacity)) ?? box)
            ctx.fill(padded)
            if style.outline {
                ctx.setStrokeColor(box)
                ctx.setLineWidth(2 * scale)
                ctx.stroke(padded)
            }
        }
    }

    drawWatermark(ctx: ctx, width: CGFloat(w), height: CGFloat(h))

    NSGraphicsContext.restoreGraphicsState()
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
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
private func configureTextQuality(_ ctx: CGContext) {
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSubpixelQuantizeFonts(false)
    ctx.setAllowsFontSubpixelQuantization(false)
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSmoothFonts(false)
    ctx.setAllowsFontSmoothing(false)
}

/// Draws one match's replacement text, left-aligned to the box's true left edge and with its cap
/// height centred in the box.
///
/// Both of those are measured against Vision's box rather than against the padded frame or the
/// font's own line box, because Vision's box is the one thing here that came from the source
/// image: it wraps the original glyphs tightly, so its left edge is where the original word
/// started and its height is the original cap height. Centring the substitute font's *line* box
/// instead would push the text off by however much built-in leading that particular family
/// carries, which varies enormously between families (Noto Sans' line box is ~14% taller than the
/// system font's at the same cap height).
private func drawMatchText(_ text: String, in box: CGRect, size: CGFloat, ink: CGColor,
                           family: String?, style: OverlayStyle, ctx: CGContext) {
    var font: NSFont
    if style.autoFont, let family, let f = NSFont(name: renderableFontName(family: family, bold: style.weight == "bold"), size: size) {
        font = f
    } else {
        font = nsFont(size: size, weight: HL.fontWeight(style.weight), design: HL.fontDesign(style.design))
    }
    var shear: CGFloat = 0
    if style.italic {
        let real = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if real.fontDescriptor.symbolicTraits.contains(.italic) { font = real }
        // No real italic member in this family: slant it in the context instead, which is the
        // same synthetic oblique SwiftUI's .italic() falls back to, so preview and export agree.
        else { shear = 0.2 }
    }

    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: ink) ?? .black,
        .ligature: 0,   // no automatic ligatures: they change a word's measured width after fitting
    ])
    let baseline = box.minY + (box.height - font.capHeight) / 2

    ctx.saveGState()
    if shear != 0 {
        ctx.translateBy(x: box.minX, y: baseline)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: shear, d: 1, tx: 0, ty: 0))
        // draw(at:) positions the line box's bottom-left, so back off by the descender to put the
        // baseline where it was computed.
        attributed.draw(at: CGPoint(x: 0, y: font.descender))
    } else {
        attributed.draw(at: CGPoint(x: box.minX, y: baseline + font.descender))
    }
    ctx.restoreGState()
}

/// The same bottom-right badge the preview stamps on every image, at the same pixel size and
/// offsets — see watermarkPixelSize — so the export matches what was on screen.
///
/// Built here rather than blitted from a file: the background is a translucent rounded rectangle
/// and the wordmark is vector art rasterised straight into this context at its final size, which
/// is what keeps the badge's edges and letterforms clean on a full-resolution image instead of
/// upscaling a small bitmap.
private func drawWatermark(ctx: CGContext, width: CGFloat, height: CGFloat) {
    let ww = watermarkPixelSize.width, wh = watermarkPixelSize.height
    let rect = CGRect(x: width - watermarkRightMargin - ww, y: watermarkBottomMargin,
                      width: ww, height: wh)
    guard rect.minX > 0, rect.maxY < height else { return }   // image too small to carry the badge

    ctx.saveGState()
    ctx.setAlpha(watermarkOpacity)
    let r = wh * watermarkCornerFraction
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.setFillColor(cgColor(watermarkBackground))
    ctx.fillPath()
    ctx.restoreGState()

    // Centred on both axes: the SVG's box wraps the wordmark exactly, so centring the box centres
    // the letters.
    guard let art = watermarkArtwork, art.size.width > 0 else { return }
    let mw = ww * watermarkWordmarkWidthFraction
    let mh = mw * (art.size.height / art.size.width)
    art.draw(in: CGRect(x: rect.midX - mw / 2, y: rect.midY - mh / 2, width: mw, height: mh),
             from: .zero, operation: .sourceOver, fraction: watermarkOpacity)
}

extension Array {
    /// Every per-match array (colours, fonts, sizes) is built alongside `matches` and should be
    /// the same length, but a failed sample legitimately yields a short or empty array; this
    /// keeps the draw loop from trapping on that rather than silently dropping the overlay.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
