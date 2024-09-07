import Foundation
import Vision
import ImageIO

public enum OCRError: Error { case unreadable(URL) }

/// Runs Apple's on-device Vision text recognition on one image file.
public func recognizeText(at url: URL) throws -> String {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw OCRError.unreadable(url)
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US", "nl-NL"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

/// Bounding boxes (normalised 0-1, origin bottom-left, as Vision reports them) of every
/// occurrence of any of `terms` in the image's text. Case- and accent-insensitive.
public struct TextMatch: Sendable {
    public let rect: CGRect   // normalised, origin bottom-left
    public let text: String   // the text as recognised on the image
}

/// Every recognized line's full bounding box, regardless of search terms — unlike findMatches,
/// which only returns boxes for the substrings that matched a search. Meant for callers that
/// need a representative sample of everything on the page (e.g. auto font-matching, which needs
/// many data points to be reliable — scoring against just the handful of substrings a search
/// happened to match is too few to average out per-string noise).
public func allTextBoxes(at url: URL) throws -> [TextMatch] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw OCRError.unreadable(url) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US", "nl-NL"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { obs in
        guard let cand = obs.topCandidates(1).first, !cand.string.isEmpty,
              let box = try? cand.boundingBox(for: cand.string.startIndex..<cand.string.endIndex) else { return nil }
        return TextMatch(rect: box.boundingBox, text: cand.string)
    }
}

public func findMatches(at url: URL, terms: [String]) throws -> [TextMatch] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw OCRError.unreadable(url) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US", "nl-NL"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var boxes: [TextMatch] = []
    for obs in request.results ?? [] {
        guard let cand = obs.topCandidates(1).first else { continue }
        let s = cand.string
        for term in terms where !term.isEmpty {
            var from = s.startIndex
            while from < s.endIndex,
                  let r = s.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
                if let box = try? cand.boundingBox(for: r) { boxes.append(TextMatch(rect: box.boundingBox, text: String(s[r]))) }
                from = r.upperBound
            }
        }
    }
    return boxes
}
