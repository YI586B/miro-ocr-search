import SwiftUI
import AppKit
import CoreText
import ImageIO

/// Sources/assets/fonts, found through assetURL: in the app bundle, or next to the sources.
private var bundledFontsDirectory: URL { assetURL("fonts") }

/// Registers the bundled Noto Sans fonts (Sources/assets/fonts) with this process, so family
/// "Noto Sans" becomes available right alongside whatever's actually installed on the system
/// running the app — without a system-wide install. Scoped to `.process`, so it never touches
/// the system font registry; safe to call more than once. Call once at launch, before any
/// font-matching happens.
func registerBundledFonts() {
    guard let files = try? FileManager.default.contentsOfDirectory(at: bundledFontsDirectory, includingPropertiesForKeys: nil) else { return }
    for url in files where url.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

/// Common, general-purpose Latin body-text/UI font families to consider as auto-font matches.
/// Searching the *entire* installed catalog (any of ~190 families on a typical Mac, including
/// CJK fonts with Latin fallback glyphs, math/symbol fonts, and novelty/decorative faces) let a
/// completely inappropriate font coincidentally win the width comparison for some snippet — a
/// single scalar (rendered width) has very little discriminating power among that many wildly
/// different candidates. Restricting the search to fonts actually meant for reading body text
/// fixed that in testing; monospace and script/symbol-only families are excluded either way
/// (isMonospace, supportsCharacters) as a second safety net.
private let curatedFontFamilies = [
    "SF Pro", "SF Pro Text", "SF Pro Display", "SF Pro Rounded",
    "SF Compact", "SF Compact Text", "SF Compact Display", "SF Compact Rounded",
    "Helvetica Neue", "Helvetica", "Arial", "Arial Rounded MT Bold",
    "Avenir", "Avenir Next", "Avenir Next Condensed", "Futura", "Gill Sans", "Optima",
    "Verdana", "Tahoma", "Trebuchet MS",
    "Georgia", "Times New Roman", "Palatino", "Baskerville",
    "American Typewriter", "Charter", "Hoefler Text", "Big Caslon", "Cochin",
    "Didot", "Bodoni 72", "Noto Sans",
]

/// The curated families actually present (and not monospace) on the machine running the app.
func candidateFontFamilies() -> [String] {
    let available = Set(NSFontManager.shared.availableFontFamilies)
    return curatedFontFamilies.filter { available.contains($0) && !isMonospace($0) }
}

/// How much a fitted font's natural width may exceed the match box's width before the cap-height
/// fit gets shrunk to compensate — shared by fitBoth here and fittedFontSize(for:weight:design:)
/// in Settings.swift, so the manual and auto-font paths behave the same way. See fitBoth's
/// comment for why a hard zero-tolerance cutoff read as noticeably too small.
let widthTolerance: CGFloat = 1.12

private func isMonospace(_ family: String) -> Bool {
    NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?
        .fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
}

/// The font substituted in whenever the best match turns out to be a system font. Noto Sans is
/// bundled with the app (Sources/assets/fonts) and registered at launch via
/// registerBundledFonts(), so it's available even on a machine that never installed it.
let systemFontReplacement = "Noto Sans"

/// How much heavier the overlay is drawn when systemFontReplacement stands in for a detected SF
/// family: Noto Sans reads lighter than SF at the same weight, so its weight axis is raised by 5%
/// (regular 400 -> 420, bold 700 -> 735). Only for that stand-in — not when Noto Sans is detected
/// in its own right, and not when it is picked by hand.
let systemFontReplacementWeightBoost: CGFloat = 1.05

/// `font` with its weight axis multiplied by `factor`, within the axis's range. Only variable
/// fonts have that axis; anything else comes back unchanged. Keeps the rest of the font —
/// style, italic, size — as it was.
func heavier(_ font: NSFont, by factor: CGFloat) -> NSFont {
    guard factor != 1 else { return font }
    let ct = font as CTFont
    let wght = 0x77676874   // 'wght'
    guard let axis = (CTFontCopyVariationAxes(ct) as? [[CFString: Any]])?
              .first(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == wght }),
          let fallback = (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue,
          let lowest = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue,
          let highest = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue else { return font }
    // A font at its default instance (Noto Sans Regular) reports no variation at all.
    let current = ((CTFontCopyVariation(ct) as? [NSNumber: Any])?[NSNumber(value: wght)] as? NSNumber)?.doubleValue ?? fallback
    let target = min(max(current * Double(factor), lowest), highest)
    let descriptor = CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(ct),
                                                             NSNumber(value: wght) as CFNumber, CGFloat(target))
    return CTFontCreateWithFontDescriptor(descriptor, font.pointSize, nil) as NSFont
}

/// True for Apple's system UI font and its SF-branded family members (SF Pro, SF Mono, SF
/// Compact, ...).
func isSystemFont(_ family: String) -> Bool {
    family == ".AppleSystemUIFont" || family.uppercased().hasPrefix("SF")
}

private func nsFont(family: String, bold: Bool, size: CGFloat) -> NSFont? {
    NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [], weight: 5, size: size)
}

/// True if `font` has an actual glyph for every character in `text`. AppKit's width measurement
/// (NSString.size(withAttributes:)) still returns a plausible-looking number even when the font
/// can't render the text at all — CoreText silently substitutes a fallback font's metrics for
/// any glyph it's missing — so without this check, a font for a completely different script
/// (e.g. Raanana, a Hebrew-only system font with zero Latin coverage) can "win" the width race
/// for ordinary Latin text purely by the fallback font's coincidental metrics, despite being
/// unable to draw a single character of it.
private func supportsCharacters(in text: String, font: NSFont) -> Bool {
    let cs = CTFontCopyCharacterSet(font as CTFont)
    for scalar in text.unicodeScalars {
        guard let ch = unichar(exactly: scalar.value) else { continue }   // astral-plane char: skip, rare in UI text
        if !CFCharacterSetIsCharacterMember(cs, ch) { return false }
    }
    return true
}

// MARK: - detecting the font from the image

/// Below this average shape score (see rankFonts) no candidate looks enough like the text to name
/// it, and detection reports no match, so the Font and Weight settings apply instead. Measured on
/// the test images: iPhone UI text set in SF scores 0.63-0.80 for SF Pro Text, while photos
/// and custom typefaces that are not among the candidates top out around 0.27-0.39.
private let minimumShapeScore = 0.5

/// At most this many lines are compared, the longest first: more letters say more about a font,
/// and past a couple of dozen lines the ranking stops changing while the cost keeps growing.
private let maxScoredLines = 20

/// Lines are compared at this ink height at most, in pixels. Letterforms are still clearly told
/// apart at this size, and it keeps the comparison to a fraction of a second per image.
private let comparisonHeight: CGFloat = 32

/// What font detection settled on for an image.
struct DetectedFont: Sendable, Equatable {
    /// The family to draw in.
    var family: String
    /// Whether `family` is systemFontReplacement standing in for an SF family that won — the one
    /// case drawn systemFontReplacementWeightBoost heavier.
    var standsInForSystemFont: Bool
}

/// Best-guess installed font family for a whole image, or nil if nothing matches well enough.
///
/// When the winner is one of Apple's SF families, systemFontReplacement is returned in its place:
/// that is a deliberate choice, not a detection result, so rankFonts still reports the SF family.
func detectedFont(forImage items: [(text: String, rect: CGRect)], path: String, pixelSize: CGSize,
                from families: [String] = candidateFontFamilies()) -> DetectedFont? {
    guard let winner = rankFonts(forImage: items, path: path, pixelSize: pixelSize, from: families).first,
          winner.score >= minimumShapeScore else { return nil }
    if isSystemFont(winner.family), NSFontManager.shared.availableFontFamilies.contains(systemFontReplacement) {
        return DetectedFont(family: systemFontReplacement, standsInForSystemFont: true)
    }
    return DetectedFont(family: winner.family, standsInForSystemFont: false)
}

/// The family detectedFont settles on, without saying whether it is a stand-in.
func bestMatchingFont(forImage items: [(text: String, rect: CGRect)], path: String, pixelSize: CGSize,
                      from families: [String] = candidateFontFamilies()) -> String? {
    detectedFont(forImage: items, path: path, pixelSize: pixelSize, from: families)?.family
}

/// Every candidate family that could be scored, best first, by how closely its letter shapes match
/// the text on the image.
///
/// Each line's glyphs are measured off the image (sampledInk) and cut out; the line is then drawn
/// in the candidate font, scaled so its glyph outlines fill exactly the same box, and the two are
/// compared pixel by pixel (normalised cross-correlation of ink strength: 1 is identical). Regular
/// and bold are both tried per line, since images mix weights. A family's score is its
/// average over the lines it can draw.
///
/// This replaced comparing a single number — how wide the text comes out at the height of Vision's
/// box — which could not tell fonts apart. Vision's box runs 8-11% taller than the ink, and each
/// family reserves a different amount of line height around its letters, so that number rewarded
/// wide, short-lined fonts: Verdana won on every iPhone image, with SF Pro Text fourth to
/// sixth. Compared by shape, SF Pro Text ranks first on all of them.
func rankFonts(forImage items: [(text: String, rect: CGRect)], path: String, pixelSize: CGSize,
               from families: [String] = candidateFontFamilies()) -> [(family: String, score: Double)] {
    let usable = items.filter { $0.text.trimmingCharacters(in: .whitespaces).count > 1 }
    guard !usable.isEmpty, pixelSize.width > 0, pixelSize.height > 0, !families.isEmpty,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    let ink = sampledInk(at: path, rects: usable.map(\.rect))
    let W = CGFloat(image.width), H = CGFloat(image.height)

    // The lines to compare, longest first, each cut out of the image as ink strength.
    let lines = usable.indices
        .compactMap { i -> (text: String, ink: CGRect)? in
            guard let s = ink[i] ?? nil, s.rect.height * H > 6, s.rect.width * W > 2 else { return nil }
            return (usable[i].text, s.rect)
        }
        .sorted { $0.text.count > $1.text.count }
        .prefix(maxScoredLines)
    let crops = lines.map { line in inkCrop(of: image, ink: line.ink, width: W, height: H) }

    let scored = families.compactMap { family -> (family: String, score: Double)? in
        guard nsFont(family: family, bold: false, size: 12) != nil else { return nil }
        var total = 0.0, n = 0
        for (line, crop) in zip(lines, crops) {
            let best = [false, true].compactMap { bold -> Double? in
                guard let font = nsFont(family: family, bold: bold, size: 100),
                      supportsCharacters(in: line.text, font: font) else { return nil }
                return shapeScore(line.text, font: font, against: crop)
            }.max()
            if let best { total += best; n += 1 }
        }
        // A family that can only draw a few of the lines would be judged on a flattering subset.
        guard n > 0, n * 2 >= lines.count else { return nil }
        return (family, total / Double(n))
    }
    return scored.sorted { $0.score > $1.score }
}

/// One line's glyphs cut out of the image as ink strength — each pixel's distance from the
/// background level, taken as the median of the crop's border — at no more than
/// comparisonHeight, with a small margin all round.
private struct InkCrop {
    var pixels: [Double]
    var width: Int, height: Int
    /// The glyph box inside the crop, in crop pixels, bottom-left origin.
    var ink: CGRect
}

private let cropMargin: CGFloat = 3

private func inkCrop(of image: CGImage, ink: CGRect, width W: CGFloat, height H: CGFloat) -> InkCrop {
    let k = min(1, comparisonHeight / (ink.height * H))
    let iw = ink.width * W * k, ih = ink.height * H * k
    let w = Int((iw + 2 * cropMargin).rounded(.up)), h = Int((ih + 2 * cropMargin).rounded(.up))
    var g = grayPixels(width: w, height: h) { ctx in
        ctx.interpolationQuality = .high
        ctx.translateBy(x: cropMargin - ink.minX * W * k, y: cropMargin - ink.minY * H * k)
        ctx.scaleBy(x: k, y: k)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    var border: [Double] = []
    for x in 0..<w { border.append(g[x]); border.append(g[(h - 1) * w + x]) }
    for y in 0..<h { border.append(g[y * w]); border.append(g[y * w + w - 1]) }
    let background = border.sorted()[border.count / 2]
    g = g.map { abs($0 - background) }
    return InkCrop(pixels: g, width: w, height: h, ink: CGRect(x: cropMargin, y: cropMargin, width: iw, height: ih))
}

/// How closely `text` drawn in `font`, stretched to fill the crop's glyph box, matches the crop.
private func shapeScore(_ text: String, font: NSFont, against crop: InkCrop) -> Double? {
    let bounds = glyphBounds(of: text, font: font)
    guard bounds.width > 1, bounds.height > 1 else { return nil }
    let sx = crop.ink.width / bounds.width, sy = crop.ink.height / bounds.height
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
        attributes: [.font: font, .foregroundColor: NSColor.white, .ligature: 0]))
    let drawn = grayPixels(width: crop.width, height: crop.height) { ctx in
        ctx.translateBy(x: crop.ink.minX - bounds.minX * sx, y: crop.ink.minY - bounds.minY * sy)
        ctx.scaleBy(x: sx, y: sy)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
    }
    return correlation(crop.pixels, drawn)
}

/// A grayscale bitmap, black to start with, drawn into by `draw`, as values from 0 to 1.
private func grayPixels(width: Int, height: Int, _ draw: (CGContext) -> Void) -> [Double] {
    guard width > 0, height > 0,
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let data = ctx.data else { return [] }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(ctx)
    let buf = data.bindMemory(to: UInt8.self, capacity: width * height)
    return (0..<(width * height)).map { Double(buf[$0]) / 255 }
}

/// Normalised cross-correlation: 1 when the two images have the same shape, 0 when unrelated.
private func correlation(_ a: [Double], _ b: [Double]) -> Double? {
    guard a.count == b.count, !a.isEmpty else { return nil }
    let n = Double(a.count), ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
    var ab = 0.0, aa = 0.0, bb = 0.0
    for i in a.indices {
        let x = a[i] - ma, y = b[i] - mb
        ab += x * y; aa += x * x; bb += y * y
    }
    return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : nil
}

/// Largest size at which `family` fits `text` inside *both* dimensions of `box` — the actual
/// on-screen render size. Rendering needs to fit the box the same way fittedFontSize(for:weight:design:fitting:) does for the
/// manual/design path: sized by cap height, not the font's full line-height metric. Different
/// families carry wildly different amounts of built-in leading for the same visible glyph size
/// (measured, Noto Sans's line height runs ~14% taller than SF's at the same point size, despite
/// their cap heights being within 2% of each other) — fitting against the full line height, as
/// this used to, systematically under-sized any family with generous default leading relative to
/// what the original text actually looked like.
private func fitBoth(text: String, family: String, bold: Bool, weightBoost: CGFloat, box: CGSize) -> CGFloat {
    guard let plain = nsFont(family: family, bold: bold, size: 100), supportsCharacters(in: text, font: plain) else { return 4 }
    let base = heavier(plain, by: weightBoost)
    let capRatio = base.capHeight / 100
    guard capRatio > 0 else { return 4 }
    var size = box.height / capRatio
    if let f = nsFont(family: family, bold: bold, size: size).map({ heavier($0, by: weightBoost) }) {
        let width = (text as NSString).size(withAttributes: [.font: f]).width
        // Vision's box is a tight fit around the *original* font's glyphs; a substitute family
        // at the same cap height routinely needs a bit more horizontal room for the same text
        // (different letter proportions), and shrinking all the way to zero tolerance pulled the
        // vertical size down with it more than the actual overflow warranted, reading as
        // noticeably smaller than the source text. A small tolerance keeps that correction from
        // over-firing on minor, expected overflow while still catching genuine blowouts.
        let allowedWidth = box.width * widthTolerance
        if width > allowedWidth, width > 0 { size *= allowedWidth / width }
    }
    return max(size, 4)
}

/// The font size MatchView actually renders a match's text at: fit to the auto-matched family
/// when auto-font is on and a match was found, otherwise fit to the manually chosen design.
func effectiveFontSize(for text: String, weight: Font.Weight, design: Font.Design,
                        matchedFamily: String?, weightBoost: CGFloat = 1, fitting box: CGSize) -> CGFloat {
    if let family = matchedFamily {
        return fitBoth(text: text, family: family, bold: weight == .bold, weightBoost: weightBoost, box: box)
    }
    return fittedFontSize(for: text, weight: weight, design: design, fitting: box)
}

/// The exact renderable name (PostScript name, e.g. "NotoSans-Bold") for a family/weight combo —
/// what SwiftUI's Font.custom(_:size:) needs to reliably pick up a font. A bare family name isn't
/// guaranteed to resolve there the same way AppKit's NSFont(name:) resolves it, and when it
/// doesn't, Font.custom silently falls back to the system font — which is exactly what made
/// auto-font look like it wasn't doing anything. Falls back to the family name if resolution
/// somehow still fails, so callers always get a string to pass along.
func renderableFontName(family: String, bold: Bool) -> String {
    nsFont(family: family, bold: bold, size: 12)?.fontName ?? family
}

// MARK: - fitting to ink measured off the image

/// The tight bounding box of `text`'s glyph outlines in `font`, relative to the text's drawing
/// origin on the baseline: `minX` is the left side bearing, `minY` is how far the lowest ink falls
/// below the baseline (negative when the string has descenders), `height` is the full ink height.
///
/// Glyph path bounds, deliberately, not the font's line metrics. Line metrics describe the
/// abstract box a typesetter reserves for a line — ascender to descender, plus leading — and
/// different families reserve very different amounts of it for the same visible letters. What has
/// to line up here is ink against ink measured off an image, so the measurement has to be of
/// the ink.
func glyphBounds(of text: String, font: NSFont, tracking: CGFloat = 0, kerning: Bool = true) -> CGRect {
    let attrs = overlayAttributes(font: font, tracking: tracking, kerning: kerning)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
}

/// The text attributes the overlay is both measured and drawn with — one definition, so a fit can
/// never be computed against different settings than the ones used to draw.
///
/// `.tracking` rather than `.kern` for letter spacing: `.kern` replaces the font's own pair
/// kerning, so using it to add space silently throws the kerning away. `.tracking` adds on top and
/// leaves kerning intact, which is why turning kerning off is a separate thing — `.kern` set to 0.
/// Ligatures stay off: they change a string's width after it has been fitted.
func overlayAttributes(font: NSFont, tracking: CGFloat, kerning: Bool) -> [NSAttributedString.Key: Any] {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .ligature: 0]
    if tracking != 0 { attrs[.tracking] = tracking }
    if !kerning { attrs[.kern] = 0 }
    return attrs
}

/// Letter spacing that makes `text` span `inkWidth` — the width the original glyphs actually
/// occupied on the image.
///
/// Fitting the size to the ink's height gets the letters the right size but not the right rhythm:
/// a substitute family distributes the same total width differently, so the two drift apart across
/// a word even when they start and end in the same place. Measured on IMG_0849, "New" sat on top
/// of the original while "Relic" had walked several pixels right. Spacing is the dimension that
/// fixes that, and it is worth recomputing on every font change, since how wrong the width is
/// depends entirely on which font was chosen.
///
/// Clamped, because a font far enough from the original would otherwise be crammed or flung apart
/// to force a width it was never going to make honestly.
func inkFittedTracking(for text: String, font: NSFont, kerning: Bool, inkWidth: CGFloat) -> CGFloat {
    let gaps = CGFloat(text.count - 1)
    guard gaps >= 1, inkWidth > 1 else { return 0 }
    let natural = glyphBounds(of: text, font: font, tracking: 0, kerning: kerning).width
    guard natural > 1 else { return 0 }
    let limit = font.pointSize * trackingLimit
    return min(max((inkWidth - natural) / gaps, -limit), limit)
}

/// How far spacing may be pushed, as a fraction of the font size. Past this the letters stop
/// looking like the word and start looking like a stretched one.
let trackingLimit: CGFloat = 0.12

/// The font a match is drawn in: `matchedFamily` when there is one, otherwise the system font in
/// the chosen design and weight. One place, so fitting and drawing cannot disagree about which
/// font they are talking about.
///
/// There is no separate "is auto-matching on" flag here on purpose. Whether the family came from
/// matching the image or from the user picking one is the caller's business; all that matters
/// here is whether there is a family to use. A nil family *is* the instruction to fall back.
/// `weightBoost` makes the matched family heavier (see systemFontReplacementWeightBoost).
func matchFont(size: CGFloat, weight: Font.Weight, design: Font.Design,
               matchedFamily: String?, weightBoost: CGFloat = 1) -> NSFont {
    if let family = matchedFamily,
       let f = NSFont(name: renderableFontName(family: family, bold: weight == .bold), size: size) {
        return heavier(f, by: weightBoost)
    }
    return nsFont(size: size, weight: weight, design: design)
}

/// Font size at which `text` fills `ink` — the box the original glyphs were measured to occupy in
/// the image — matching its height, then shrunk if that would overshoot its width by more than
/// widthTolerance.
///
/// This replaces fitting to Vision's bounding box. Vision's box is not the tight wrap around the
/// glyphs it is often taken for: measured across IMG_0849 it runs 8-11% taller than the ink inside
/// it, so solving a size from its height made every overlay that much too large — visibly so on
/// short strings, which never trip the width limit that was accidentally correcting the long ones.
func inkFittedFontSize(for text: String, weight: Font.Weight, design: Font.Design,
                       matchedFamily: String?, weightBoost: CGFloat = 1, fitting ink: CGSize) -> CGFloat {
    guard !text.isEmpty, ink.width > 1, ink.height > 1 else { return 4 }
    let probe = matchFont(size: 100, weight: weight, design: design, matchedFamily: matchedFamily,
                          weightBoost: weightBoost)
    let b = glyphBounds(of: text, font: probe)
    guard b.height > 1, b.width > 1 else { return 4 }
    var size = 100 * ink.height / b.height
    // A substitute family at the same ink height routinely needs a little more width for the same
    // letters; only a genuine blowout past the tolerance is worth correcting for, and correcting
    // it costs height, which is the dimension that was just measured exactly.
    let allowed = ink.width * widthTolerance
    let width = b.width * size / 100
    if width > allowed, width > 0 { size *= allowed / width }
    return max(size, 4)
}

/// Where to put the text's drawing origin — the point on the baseline that CTLineDraw takes — so
/// its glyphs land exactly on `ink`, the box the original glyphs occupied. Left edge to left edge,
/// bottom of the lowest ink to bottom of the lowest ink, which is why a string with descenders no
/// longer sits low: the descender is part of what is being aligned rather than something the
/// centring ignored.
func inkDrawOrigin(for text: String, font: NSFont, tracking: CGFloat, kerning: Bool,
                   ink: CGRect) -> CGPoint {
    let b = glyphBounds(of: text, font: font, tracking: tracking, kerning: kerning)
    return CGPoint(x: ink.minX - b.minX, y: ink.minY - b.minY)
}

// MARK: - matching how soft the original's edges are

/// The edge softness text drawn by drawMatchText comes out with, in pixels of 20-80% rise.
///
/// Measured across four families at three sizes: our own drawing lands between 1.18 and 1.35 and
/// does not vary meaningfully with size or family, because it is set by the rasteriser's
/// antialiasing rather than by the glyphs. A constant is therefore honest here, and far cheaper
/// than rendering each match twice to find out.
let drawnEdgeRise: CGFloat = 1.28

/// A Gaussian blur, as a standard deviation in pixels, that takes text from `drawnEdgeRise` to the
/// softness measured on the original.
///
/// Blurring convolves the two edge profiles, so their widths add in quadrature: an edge of width
/// `a` blurred by a Gaussian of width `b` comes out at sqrt(a² + b²). Solving for the blur gives
/// the expression below, where a Gaussian's own 20-80% rise is 1.683 sigma.
///
/// In practice this lands the drawn edge most of the way to the target rather than exactly on it
/// — measured, a 1.27px edge asked to reach 1.56px arrived at 1.49px. The model is approximate
/// (CIGaussianBlur's radius is not quite a standard deviation, and drawnEdgeRise is a constant
/// where the real figure varies by a tenth of a pixel or so), and the measurement itself is coarse
/// at this scale, since an edge width of about one pixel is being read off a whole-pixel grid.
/// Calibrating a correction out of numbers that noisy would be fitting the noise; the manual
/// override is there for anyone who wants to push it further.
///
/// Zero when the original is no softer than what we draw. Sharpening is not on the table — the
/// detail a resample took out is gone — so the honest answer there is to leave it alone, which is
/// also what the measurements say to do: across eight matches the original was the *crisper* one
/// in three of them.
func smoothnessToMatch(originalRise: CGFloat) -> CGFloat {
    guard originalRise > drawnEdgeRise else { return 0 }
    return (originalRise * originalRise - drawnEdgeRise * drawnEdgeRise).squareRoot() / 1.683
}

// MARK: - system-font helpers

private extension Font.Design {
    var nsDesign: NSFontDescriptor.SystemDesign {
        switch self { case .rounded: return .rounded; case .serif: return .serif
        case .monospaced: return .monospaced; default: return .default }
    }
}

func nsFont(size: CGFloat, weight: Font.Weight, design: Font.Design) -> NSFont {
    let nsWeight: NSFont.Weight = { switch weight { case .medium: return .medium
        case .bold: return .bold; default: return .regular } }()
    let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
    guard let d = base.fontDescriptor.withDesign(design.nsDesign), let f = NSFont(descriptor: d, size: size)
    else { return base }
    return f
}

/// Largest font size at which `text` (in the given weight/design) fits inside `box`, sized by
/// the font's *cap height* rather than its full line-height metric (ascender + descender +
/// leading, what NSString's own size measurement uses). Vision's bounding box tightly wraps the
/// visible glyphs, not a font's abstract line box, and different fonts/designs carry wildly
/// different amounts of built-in leading for the same visible glyph size — measured against full
/// line height, a design with generous leading gets fitted to a noticeably smaller point size to
/// hit the same box height, even though its actual letters are the same size as one with tighter
/// leading. Cap height scales linearly with point size and is close to font-invariant as a
/// fraction of it, so solving directly from it (no search needed for height) keeps the *visible*
/// text size consistent across designs instead of just the measured line box.
func fittedFontSize(for text: String, weight: Font.Weight, design: Font.Design, fitting box: CGSize) -> CGFloat {
    guard !text.isEmpty, box.width > 1, box.height > 1 else { return 4 }
    let probe = nsFont(size: 100, weight: weight, design: design)
    let capRatio = probe.capHeight / 100
    guard capRatio > 0 else { return 4 }
    var size = box.height / capRatio
    let f = nsFont(size: size, weight: weight, design: design)
    let width = (text as NSString).size(withAttributes: [.font: f]).width
    let allowedWidth = box.width * widthTolerance   // see widthTolerance in FontMatch.swift
    if width > allowedWidth, width > 0 { size *= allowedWidth / width }
    return max(size, 4)
}
