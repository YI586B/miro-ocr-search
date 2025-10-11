import AppKit
import SwiftUI
import OCRSearchCore

// MARK: - style snapshot

/// The persisted overlay look (the HL.* defaults), snapshotted into a plain value so a render can
/// run off the main actor without reading @AppStorage — which is a SwiftUI view-side wrapper and
/// isn't available to the export path, whether that runs from the preview window's Save command
/// or from a batch export with no preview window open at all.
struct OverlayStyle: Sendable, Codable, Equatable {
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
    /// Fixed size for every match, in points — the unit that means the same thing whatever the
    /// image's own resolution is, and independent of how the window happens to be showing it.
    /// 0 = fit each match individually. See RenderPlan.imageScale.
    var manualSize: Double = 0
    var italic = false

    // MARK: per image
    //
    // The look is stored per image, not once for the app. Every image is a different screenshot
    // with its own type sizes and colours, so a font or size that is right for one is usually
    // wrong for the next; sharing one set of values meant tuning an image silently restyled every
    // other one, and there was no way to go back to what a given image looked like. The Settings
    // window still sets the defaults an image starts from.

    private static let store = "imageStyles"
    /// Enough that returning to an image from a session's work still finds its settings, bounded
    /// so the defaults file cannot grow without limit.
    private static let keep = 300

    /// The look for `path`: what was last set for that image, or the defaults if it has none.
    static func forImage(_ path: String, _ d: UserDefaults = .standard) -> OverlayStyle {
        guard let raw = d.dictionary(forKey: store)?[path] as? Data,
              let s = try? JSONDecoder().decode(OverlayStyle.self, from: raw) else { return current(d) }
        return s
    }

    func save(for path: String, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        var all = d.dictionary(forKey: Self.store) ?? [:]
        all[path] = data
        // Oldest-first eviction is not worth a timestamp per entry; dropping arbitrary extras once
        // over the cap only costs those images their overrides, and they fall back to the defaults.
        if all.count > Self.keep {
            all = all.prefix(Self.keep).reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        }
        d.set(all, forKey: Self.store)
    }

    static func clear(_ path: String, _ d: UserDefaults = .standard) {
        guard var all = d.dictionary(forKey: store) else { return }
        all[path] = nil
        d.set(all, forKey: store)
    }

    /// Writes this look back as the defaults every image starts from.
    func saveAsDefaults(_ d: UserDefaults = .standard) {
        d.set(show, forKey: HL.show); d.set(mode, forKey: HL.mode)
        d.set(boxHex, forKey: HL.boxHex); d.set(opacity, forKey: HL.opacity)
        d.set(outline, forKey: HL.outline); d.set(textHex, forKey: HL.textHex)
        d.set(autoTextColor, forKey: HL.autoTextColor); d.set(bgHex, forKey: HL.bgHex)
        d.set(autoBg, forKey: HL.autoBg); d.set(design, forKey: HL.design)
        d.set(weight, forKey: HL.weight); d.set(autoFont, forKey: HL.autoFont)
        d.set(manualFont, forKey: HL.manualFont); d.set(manualSize, forKey: HL.manualSize)
        d.set(italic, forKey: HL.italic)
    }

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

    /// Does from scratch what PreviewView does incrementally as an image loads: find the matches,
    /// sample each one's background and ink colour, auto-match a font family across the whole
    /// page, then fit a size per match — all in the image's own pixel units.
    static func build(path: String, query: String, searchMode: SearchMode, style: OverlayStyle) -> RenderPlan {
        let px = imagePixelSize(at: path) ?? .zero
        let pointScale = imagePointScale(at: path)
        let url = URL(fileURLWithPath: path)
        let terms = searchTerms(query, mode: searchMode)
        let matches = (style.show && !terms.isEmpty)
            ? ((try? findMatches(at: url, terms: terms)) ?? [])
            : []
        guard !matches.isEmpty, px.width > 0, px.height > 0 else {
            return RenderPlan(pixelSize: px, imageScale: pointScale, matches: [], bgColors: [], ink: [],
                              matchedFonts: [], fontSizes: [])
        }
        let rects = matches.map(\.rect)
        let bg = style.mode == "text" ? sampledBackgroundColors(at: path, rects: rects) : []
        let ink = style.mode == "text" ? sampledInk(at: path, rects: rects) : []

        var family: String? = style.manualFont.isEmpty ? nil : style.manualFont
        if style.autoFont, family == nil {
            let all = ((try? allTextBoxes(at: url)) ?? []).map { (text: $0.text, rect: $0.rect) }
            family = bestMatchingFont(forImage: all, pixelSize: px, from: candidateFontFamilies())
        }
        let families = Array(repeating: family, count: matches.count)
        let sizes = matches.enumerated().map { i, m -> CGFloat in
            let w = HL.fontWeight(style.weight), d = HL.fontDesign(style.design)
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
        return RenderPlan(pixelSize: px, imageScale: pointScale, matches: matches, bgColors: bg, ink: ink,
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

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    drawOverlay(in: ctx, canvas: CGSize(width: w, height: h), plan: plan, style: style)
    // Only when the overlay is on: with it off the export is the image as it is, and a watermark
    // would be the one thing contradicting that.
    if style.show { drawWatermark(ctx: ctx, width: CGFloat(w), height: CGFloat(h)) }
    NSGraphicsContext.restoreGraphicsState()
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
}

/// Draws every match's overlay — box, or replacement text over a patch — onto `ctx`, whose canvas
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

        if style.mode == "text" {
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
            drawMatchText(m.text, ink: inkRect, box: boxRect, size: size, color: inkColor,
                          family: plan.matchedFonts[safe: i] ?? nil, style: style, ctx: ctx)
        } else {
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
                           family: String?, style: OverlayStyle, ctx: CGContext) {
    var font = matchFont(size: size, weight: HL.fontWeight(style.weight),
                         design: HL.fontDesign(style.design), matchedFamily: family)
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
        .foregroundColor: NSColor(cgColor: color) ?? .black,
        .ligature: 0,   // no automatic ligatures: they change a word's measured width after fitting
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let origin: CGPoint
    if let ink, ink.height > 1 {
        origin = inkDrawOrigin(for: text, font: font, ink: ink)
    } else {
        origin = CGPoint(x: box.minX, y: box.minY + (box.height - font.capHeight) / 2)
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
