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
                        matchedFamily: String?, autoFont: Bool, fitting box: CGSize) -> CGFloat {
    if autoFont, let family = matchedFamily {
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
func glyphBounds(of text: String, font: NSFont) -> CGRect {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
}

/// The font a match is drawn in: the auto-matched family when there is one, otherwise the
/// system font in the chosen design and weight. One place, so fitting and drawing cannot
/// disagree about which font they are talking about.
func matchFont(size: CGFloat, weight: Font.Weight, design: Font.Design,
               matchedFamily: String?, autoFont: Bool) -> NSFont {
    if autoFont, let family = matchedFamily,
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
                       matchedFamily: String?, autoFont: Bool, fitting ink: CGSize) -> CGFloat {
    guard !text.isEmpty, ink.width > 1, ink.height > 1 else { return 4 }
    let probe = matchFont(size: 100, weight: weight, design: design,
                          matchedFamily: matchedFamily, autoFont: autoFont)
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
func inkDrawOrigin(for text: String, font: NSFont, ink: CGRect) -> CGPoint {
    let b = glyphBounds(of: text, font: font)
    return CGPoint(x: ink.minX - b.minX, y: ink.minY - b.minY)
}
