import SwiftUI
import AppKit
import CoreText

/// Sources/assets/fonts, resolved relative to this source file's own location rather than the
/// process's current working directory, so it's found the same way whether the app is launched
/// via `swift run`, run-app.command, or the built binary directly.
private var bundledFontsDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FontMatch.swift -> Sources/OCRSearchApp/
        .deletingLastPathComponent()   // -> Sources/
        .appendingPathComponent("assets/fonts")
}

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

/// Largest size at which `family` fits `text` inside `box` (both width and height), and the
/// resulting measured width — mirrors fittedFontSize(for:weight:design:fitting:) but for a named
/// installed font instead of one of the four built-in system designs.
private func fit(text: String, family: String, bold: Bool, box: CGSize) -> (size: CGFloat, width: CGFloat)? {
    guard let base = nsFont(family: family, bold: bold, size: 12), supportsCharacters(in: text, font: base) else { return nil }
    func measure(_ size: CGFloat) -> CGSize? {
        guard let f = nsFont(family: family, bold: bold, size: size) else { return nil }
        return (text as NSString).size(withAttributes: [.font: f])
    }
    guard let m0 = measure(4) else { return nil }
    var lo: CGFloat = 4, hi = box.height * 1.6
    var bestSize = lo, bestWidth = m0.width
    for _ in 0..<10 {
        let mid = (lo + hi) / 2
        guard let m = measure(mid) else { break }
        if m.height <= box.height { lo = mid; bestSize = mid; bestWidth = m.width } else { hi = mid }
    }
    return (bestSize, bestWidth)
}

/// How much worse the best system-font candidate's average error is allowed to be than the
/// outright winner's, and still count as "the image is basically system-font text" — see
/// bestMatchingFont(forImage:). Tuned against real screenshots: San Francisco is very often not
/// literally the #1 candidate by width alone (other fonts can measure numerically closer without
/// actually looking like a match — a wide, loosely-spaced font like Verdana can coincidentally
/// absorb the gap between Vision's OCR boxes and true glyph width better than SF's tighter
/// spacing, image-wide, without genuinely resembling it), but it should still rank competitively
/// close when the text really is set in it.
private let systemFontTolerance = 2.5

/// Best-guess installed font family for a whole image's worth of matches, not judged one string
/// at a time: for each candidate, average its *relative* width error (measured/actual width,
/// fit to each match's box height) across every match, trying both regular and bold per match
/// and keeping whichever measures closer (screenshot text mixes weights — headers vs. body —
/// that a single global weight assumption would otherwise measure against incorrectly). A font
/// that's only coincidentally close for one string won't stay close across many different ones,
/// which judging each match independently was vulnerable to.
///
/// San Francisco often isn't the literal lowest-error candidate (see systemFontTolerance above),
/// so rather than requiring it to outright win, substitute systemFontReplacement whenever the
/// best system-font candidate's error is within `systemFontTolerance` of the true winner's.
func bestMatchingFont(forImage items: [(text: String, rect: CGRect)], pixelSize: CGSize,
                       from families: [String] = candidateFontFamilies()) -> String? {
    let usable = items.filter { $0.text.count > 1 }   // single characters barely constrain width
    guard !usable.isEmpty, pixelSize.width > 0, pixelSize.height > 0, !families.isEmpty else { return nil }

    // Whether a family can be scored at all against every line on the page (used below); the
    // per-line character-coverage check inside fit() already skips lines it can't render, so
    // this only needs to confirm the family exists, not that it covers everything — requiring
    // that would disqualify the whole family over a single exotic character anywhere on the page
    // (a bullet, a chevron, an emoji — all common in real screenshots), which was silently
    // emptying `scored` entirely and made auto-font fall back to the manual Font/Weight design.
    func averageRelativeError(_ family: String) -> Double? {
        guard nsFont(family: family, bold: false, size: 12) != nil else { return nil }
        var total = 0.0, n = 0
        for it in usable {
            let box = CGSize(width: it.rect.width * pixelSize.width, height: it.rect.height * pixelSize.height)
            guard box.width > 1, box.height > 1 else { continue }
            let widths = [fit(text: it.text, family: family, bold: false, box: box)?.width,
                          fit(text: it.text, family: family, bold: true, box: box)?.width].compactMap { $0 }
            guard let width = widths.min(by: { abs($0 - box.width) < abs($1 - box.width) }) else { continue }
            total += Double(abs(width - box.width)) / Double(box.width)
            n += 1
        }
        return n > 0 ? total / Double(n) : nil
    }

    let scored = families.compactMap { family in averageRelativeError(family).map { (family, $0) } }
    guard let winner = scored.min(by: { $0.1 < $1.1 }) else { return nil }
    if let sfBest = scored.filter({ isSystemFont($0.0) }).min(by: { $0.1 < $1.1 }),
       sfBest.1 <= winner.1 * systemFontTolerance,
       NSFontManager.shared.availableFontFamilies.contains(systemFontReplacement) {
        return systemFontReplacement
    }
    return winner.0
}

/// Largest size at which `family` fits `text` inside *both* dimensions of `box` — the actual
/// on-screen render size. Unlike `fit()` above (which only constrains height, deliberately, so
/// it can measure a candidate's natural width against the target for scoring), rendering needs
/// to fit the box the same way fittedFontSize(for:weight:design:fitting:) does for the
/// manual/design path: sized by cap height, not the font's full line-height metric. Different
/// families carry wildly different amounts of built-in leading for the same visible glyph size
/// (measured, Noto Sans's line height runs ~14% taller than SF's at the same point size, despite
/// their cap heights being within 2% of each other) — fitting against the full line height, as
/// this used to, systematically under-sized any family with generous default leading relative to
/// what the original text actually looked like.
private func fitBoth(text: String, family: String, bold: Bool, box: CGSize) -> CGFloat {
    guard let base = nsFont(family: family, bold: bold, size: 100), supportsCharacters(in: text, font: base) else { return 4 }
    let capRatio = base.capHeight / 100
    guard capRatio > 0 else { return 4 }
    var size = box.height / capRatio
    if let f = nsFont(family: family, bold: bold, size: size) {
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
                        matchedFamily: String?, fitting box: CGSize) -> CGFloat {
    if let family = matchedFamily {
        return fitBoth(text: text, family: family, bold: weight == .bold, box: box)
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
/// to line up here is ink against ink measured off a screenshot, so the measurement has to be of
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
func matchFont(size: CGFloat, weight: Font.Weight, design: Font.Design,
               matchedFamily: String?) -> NSFont {
    if let family = matchedFamily,
       let f = NSFont(name: renderableFontName(family: family, bold: weight == .bold), size: size) {
        return f
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
                       matchedFamily: String?, fitting ink: CGSize) -> CGFloat {
    guard !text.isEmpty, ink.width > 1, ink.height > 1 else { return 4 }
    let probe = matchFont(size: 100, weight: weight, design: design, matchedFamily: matchedFamily)
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
