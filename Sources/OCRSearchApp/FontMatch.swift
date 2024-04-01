import SwiftUI
import AppKit

/// Installed font family names usable as text-overlay match candidates. Excludes Apple's hidden
/// internal families (dot-prefixed, e.g. ".AppleSystemUIFont") and San Francisco and all its
/// variants (any family name starting with "SF", e.g. "SF Pro", "SF Mono", "SF Compact") — SF is
/// already the system default almost everywhere, so matching a screenshot's text to yet another
/// SF variant is rarely the useful answer.
func candidateFontFamilies() -> [String] {
    (NSFontManager.shared.availableFontFamilies)
        .filter { !$0.hasPrefix(".") && !$0.uppercased().hasPrefix("SF") }
        .sorted()
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
func bestMatchingFont(for text: String, bold: Bool, fitting box: CGSize,
                       from families: [String] = candidateFontFamilies()) -> String? {
    guard !text.isEmpty, box.width > 1, box.height > 1, !families.isEmpty else { return nil }
    var best: (family: String, diff: CGFloat)?
    for family in families {
        guard let (_, width) = fit(text: text, family: family, bold: bold, box: box) else { continue }
        let diff = abs(width - box.width)
        if best == nil || diff < best!.diff { best = (family, diff) }
    }
    return best?.family
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
