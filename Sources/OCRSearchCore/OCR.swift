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
