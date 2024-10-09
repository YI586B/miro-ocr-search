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
        if width > box.width, width > 0 { size *= box.width / width }
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
