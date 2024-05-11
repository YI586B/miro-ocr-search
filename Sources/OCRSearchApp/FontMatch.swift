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

/// Installed font family names usable as text-overlay match candidates. Excludes only Apple's
/// hidden internal pseudo-families (dot-prefixed, e.g. ".AppleSystemUIFont"), which aren't real,
/// renderable fonts. San Francisco is left in the running — see bestMatchingFont, which swaps it
/// (and anything else that reads as a system font) out for a fixed replacement afterward, since
/// excluding it from the search here just made the matcher settle on an equally system-looking
/// lookalike (Helvetica Neue, etc.) instead.
func candidateFontFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted()
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

/// Largest size at which `family` fits `text` inside `box` (both width and height), and the
/// resulting measured width — mirrors fittedFontSize(for:weight:design:fitting:) but for a named
/// installed font instead of one of the four built-in system designs.
private func fit(text: String, family: String, bold: Bool, box: CGSize) -> (size: CGFloat, width: CGFloat)? {
    guard nsFont(family: family, bold: bold, size: 12) != nil else { return nil }
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

/// Best-guess installed font family for a match's text: the candidate whose rendered width, at a
/// size fit to the box's height, comes closest to the box's actual width. A fast, real-metric
/// proxy for "looks like this" — character proportions (condensed/wide, tight/loose spacing)
/// vary enough between families that width-at-matched-height is a decent visual-similarity
/// signal without full pixel-level font recognition.
///
/// Screenshot text is usually already set in the system font, so the metrically closest
/// candidate is often San Francisco itself, or a lookalike (Helvetica Neue, etc.) that measures
/// almost the same — either way it still just reads as "the system font" once drawn. If the
/// winner is a system font, swap it for systemFontReplacement instead of returning it as-is.
func bestMatchingFont(for text: String, bold: Bool, fitting box: CGSize,
                       from families: [String] = candidateFontFamilies()) -> String? {
    guard !text.isEmpty, box.width > 1, box.height > 1, !families.isEmpty else { return nil }
    var best: (family: String, diff: CGFloat)?
    for family in families {
        guard let (_, width) = fit(text: text, family: family, bold: bold, box: box) else { continue }
        let diff = abs(width - box.width)
        if best == nil || diff < best!.diff { best = (family, diff) }
    }
    guard let chosen = best?.family else { return nil }
    if isSystemFont(chosen), NSFontManager.shared.availableFontFamilies.contains(systemFontReplacement) {
        return systemFontReplacement
    }
    return chosen
}

/// The font size MatchView actually renders a match's text at: fit to the auto-matched family
/// when auto-font is on and a match was found, otherwise fit to the manually chosen design.
func effectiveFontSize(for text: String, weight: Font.Weight, design: Font.Design,
                        matchedFamily: String?, autoFont: Bool, fitting box: CGSize) -> CGFloat {
    if autoFont, let family = matchedFamily {
        return fit(text: text, family: family, bold: weight == .bold, box: box)?.size ?? 4
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
