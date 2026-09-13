import Foundation
import Vision
import ImageIO
import CoreText

public enum OCRError: Error { case unreadable(URL) }

/// An image's pixel dimensions, read from its metadata without decoding the full bitmap.
public func imagePixelSize(at path: String) -> CGSize? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
    return CGSize(width: w, height: h)
}

public struct TextMatch: Sendable {
    public let rect: CGRect   // normalised, origin bottom-left
    public let text: String   // the text as recognised on the image
}

/// One pass of Apple's on-device Vision text recognition over an image, kept so that everything
/// asked of the page — its text, the boxes of a search's matches, every line for font detection —
/// comes from the same pass instead of recognising the image again for each.
///
/// Unchecked Sendable: Vision's results are not marked Sendable, but nothing here changes them
/// after init, and a page is handed from one task to the next rather than shared between them.
public final class RecognizedPage: @unchecked Sendable {
    /// The top candidate for each line Vision found, in its order.
    private let lines: [VNRecognizedText]

    public init(at url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw OCRError.unreadable(url) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "nl-NL"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        lines = (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    /// The page's text, one recognised line per line.
    public var text: String { lines.map(\.string).joined(separator: "\n") }

    /// Every recognized line's full bounding box, regardless of search terms — unlike matches,
    /// which only returns boxes for the substrings that matched a search. Meant for callers that
    /// need a representative sample of everything on the page (e.g. auto font-matching, which
    /// needs many data points to be reliable — scoring against just the handful of substrings a
    /// search happened to match is too few to average out per-string noise).
    public var allTextBoxes: [TextMatch] {
        lines.compactMap { cand in
            guard !cand.string.isEmpty,
                  let box = try? cand.boundingBox(for: cand.string.startIndex..<cand.string.endIndex) else { return nil }
            return TextMatch(rect: box.boundingBox, text: cand.string)
        }
    }

    /// Bounding boxes (normalised 0-1, origin bottom-left, as Vision reports them) of every
    /// occurrence of any of `terms` in the image's text. Case- and accent-insensitive.
    public func matches(for terms: [String]) -> [TextMatch] {
        var boxes: [TextMatch] = []
        for cand in lines {
            let s = cand.string
            for term in terms where !term.isEmpty {
                var from = s.startIndex
                while from < s.endIndex,
                      let r = s.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
                    if let box = try? cand.boundingBox(for: r) {
                        boxes.append(TextMatch(rect: narrowed(box.boundingBox, range: r, of: cand), text: String(s[r])))
                    }
                    from = r.upperBound
                }
            }
        }
        return boxes
    }
}

/// A word's box, when Vision gave it its whole line's.
///
/// Vision measures a range by the words its recogniser segmented, and a line with no breaks in it —
/// a URL, a file path, an identifier — is one word to it, so asking for part of one returns the
/// box of all of it. Drawn over, that wipes out the whole line and stretches the word across it.
/// When a range well short of its line comes back that wide, its place is estimated instead from
/// how much of the line's width the text before it and the text itself take, set in the system
/// font: approximate, since the real font is not known yet, but in the right place.
private func narrowed(_ box: CGRect, range r: Range<String.Index>, of cand: VNRecognizedText) -> CGRect {
    let s = cand.string
    guard r != s.startIndex..<s.endIndex, s[r].count * 10 < s.count * 6,
          let full = try? cand.boundingBox(for: s.startIndex..<s.endIndex)?.boundingBox,
          box.width >= full.width * 0.9 else { return box }
    let font = CTFontCreateUIFontForLanguage(.system, 12, nil)
    func width(_ t: Substring) -> CGFloat {
        let attrs = [NSAttributedString.Key(kCTFontAttributeName as String): font as Any]
        return CGFloat(CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: String(t), attributes: attrs) as CFAttributedString),
            nil, nil, nil))
    }
    let total = width(s[...])
    guard total > 0 else { return box }
    let start = width(s[..<r.lowerBound]) / total, end = width(s[..<r.upperBound]) / total
    return CGRect(x: full.minX + full.width * start, y: box.minY,
                  width: full.width * (end - start), height: box.height)
}

/// Runs Apple's on-device Vision text recognition on one image file.
public func recognizeText(at url: URL) throws -> String { try RecognizedPage(at: url).text }

/// See RecognizedPage.allTextBoxes.
public func allTextBoxes(at url: URL) throws -> [TextMatch] { try RecognizedPage(at: url).allTextBoxes }

/// See RecognizedPage.matches(for:).
public func findMatches(at url: URL, terms: [String]) throws -> [TextMatch] { try RecognizedPage(at: url).matches(for: terms) }
