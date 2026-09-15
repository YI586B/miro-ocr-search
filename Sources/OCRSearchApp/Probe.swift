import AppKit
import SwiftUI
import OCRSearchCore
import CryptoKit

/// `OCRSearchApp --probe <folder> <search> <find on image> <out>`: does what a person does in the
/// app, without a window. Searches the folder the way the search window does, opens each image it
/// lists the way the preview window does — through PreviewModel, with the saved settings — then
/// types the second text into the preview's search field. For each image it writes what the
/// preview shows (preview.png), a side-by-side of every match (original left, overlay right) and
/// report.txt with what was detected and fitted.
///
/// Run it from the app bundle (Miro-ocr-search.app/Contents/MacOS/OCRSearchApp) so it reads the
/// app's own saved settings rather than a bare executable's empty ones.
@MainActor enum Probe {
    static func runIfRequested() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--survey"), a.count > i + 2 {
            survey(folder: URL(fileURLWithPath: a[i + 1]), out: URL(fileURLWithPath: a[i + 2]))
            exit(0)
        }
        guard let i = a.firstIndex(of: "--probe"), a.count > i + 4 else { return }
        run(folder: URL(fileURLWithPath: a[i + 1]), search: a[i + 2], find: a[i + 3],
            out: URL(fileURLWithPath: a[i + 4]))
        exit(0)
    }

    static func run(folder: URL, search: String, find: String, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // The search window: every image under the folder, its text, and a case-insensitive
        // match of every term.
        let images = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .filter { imageExts.contains($0.pathExtension.lowercased()) } ?? []).sorted { $0.path < $1.path }
        let terms = searchTerms(search, mode: .phrase)
        let hits = images.filter { url in
            guard let text = try? recognizeText(at: url) else { return false }
            return terms.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
        }
        print("searched \(images.count) images for \"\(search)\": \(hits.count) found")
        for url in hits { print("  \(url.lastPathComponent)") }

        for url in hits {
            let path = url.path
            let name = url.deletingPathExtension().lastPathComponent
            // The preview window: the image's saved look with the app-wide switches, opened with
            // the search it came from, then the second text typed into its search field.
            let style = OverlayStyle.forImage(path)
            let model = PreviewModel()
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                await model.load(path: path, query: search, searchMode: .phrase, style: style)
                await model.search(query: find, searchMode: .phrase)
                flag.done = true
            }
            while !flag.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }

            let plan = model.plan, drawn = model.drawingStyle
            guard let png = renderExportPNG(path: path, query: find, searchMode: .phrase, style: drawn, plan: plan)
            else { print("could not render \(path)"); continue }
            try? png.write(to: out.appendingPathComponent("\(name)-preview.png"))

            var report = "image \(path)\n"
            report += "pixels \(Int(plan.pixelSize.width))x\(Int(plan.pixelSize.height)), \(Int(plan.imageScale)) px/pt\n"
            report += "style: boxes \(drawn.showBoxes), text \(drawn.showText), autoFont \(drawn.autoFont), "
                + "manualFont \"\(drawn.manualFont)\", design \(drawn.design.rawValue), weight \(drawn.weight.rawValue), "
                + "italic \(drawn.italic), manualSize \(drawn.manualSize), autoTextColor \(drawn.autoTextColor), "
                + "autoBg \(drawn.autoBg), box \(drawn.boxHex) fill \(drawn.opacity) outline \(drawn.outline)\n"
            let perMatch = model.matches.indices.map { i -> String in
                let d = model.detections[safe: i] ?? nil
                return (d.map { "\($0.family)\($0.standsInForSystemFont ? " (for SF)" : "")" } ?? "no match")
                    + " -> \((model.families[safe: i] ?? nil) ?? "system font") x\(model.weightBoosts[safe: i] ?? 1)"
            }
            report += "detected per match: " + (perMatch.isEmpty ? "-" : perMatch.joined(separator: "; ")) + "\n"
            if let page = try? RecognizedPage(at: url) {
                let items = page.allTextBoxes.map { (text: $0.text, rect: $0.rect) }
                let ranking = rankFonts(forImage: items, path: path, pixelSize: plan.pixelSize).prefix(6)
                report += "ranking: " + ranking.map { "\($0.family) \(String(format: "%.3f", $0.score))" }.joined(separator: ", ") + "\n"
            }
            report += "\"\(find)\": \(plan.matches.count) matches\n"
            for (i, m) in plan.matches.enumerated() {
                func px(_ r: CGRect) -> String {
                    let W = plan.pixelSize.width, H = plan.pixelSize.height
                    return "x \(Int(r.minX * W)) y \(Int((1 - r.maxY) * H)) w \(Int(r.width * W)) h \(Int(r.height * H))"
                }
                let ink = plan.ink[safe: i] ?? nil
                report += "  #\(i + 1) \"\(m.text)\" vision [\(px(m.rect))]"
                report += ink.map { " ink [\(px($0.rect))] edge \(String(format: "%.2f", $0.edgeRise))" } ?? " ink none"
                report += " size \(String(format: "%.1f", (plan.fontSizes[safe: i] ?? 0) / plan.imageScale))pt"
                report += " spacing \(String(format: "%.2f", (plan.trackings[safe: i] ?? 0) / plan.imageScale))pt"
                report += " blur \(String(format: "%.2f", plan.smoothness[safe: i] ?? 0))"
                report += " sharpen \(String(format: "%.2f", plan.sharpness[safe: i] ?? 1))"
                report += " weight \(plan.weights[safe: i].map { w in w.axis.map { "\(Int($0))" } ?? w.weight.rawValue } ?? "-")\n"
                if let side = sideBySide(path: path, rendered: png, around: ink?.rect ?? m.rect, pixelSize: plan.pixelSize) {
                    try? side.write(to: out.appendingPathComponent("\(name)-match\(i + 1).png"))
                }
            }
            try? report.write(to: out.appendingPathComponent("\(name)-report.txt"), atomically: true, encoding: .utf8)
            print(report)
        }
    }

    /// The area around `rect` (normalised, bottom-left origin) from the original and from the
    /// render, side by side and enlarged, so the overlay can be compared with the text it covers.
    static func sideBySide(path: String, rendered: Data, around rect: CGRect, pixelSize: CGSize) -> Data? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let rsrc = CGImageSourceCreateWithData(rendered as CFData, nil),
              let overlay = CGImageSourceCreateImageAtIndex(rsrc, 0, nil) else { return nil }
        let W = pixelSize.width, H = pixelSize.height
        let r = CGRect(x: rect.minX * W, y: (1 - rect.maxY) * H, width: rect.width * W, height: rect.height * H)
        let crop = r.insetBy(dx: -max(r.height * 1.5, 20), dy: -max(r.height, 12)).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard let a = original.cropping(to: crop), let b = overlay.cropping(to: crop) else { return nil }
        let scale = max(1, min(4, 700 / crop.width)), gap: CGFloat = 12
        let w = crop.width * scale, h = crop.height * scale
        guard let ctx = CGContext(data: nil, width: Int(w * 2 + gap), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w * 2 + gap, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(b, in: CGRect(x: w + gap, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    // MARK: - survey

    /// Every distinct image in `folder`, searched for words taken from its own text, with font
    /// matching on and no saved look — what detection and fitting do left to themselves. One line
    /// per match in survey.tsv, and a side-by-side crop of each.
    static func survey(folder: URL, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }.filter { imageExts.contains($0.pathExtension.lowercased()) } ?? [])
            .sorted { $0.path < $1.path }
        var seen = Set<Data>(), images: [URL] = []
        for u in urls {
            guard let d = try? Data(contentsOf: u) else { continue }
            let key = Data(SHA256.hash(data: d))
            if seen.insert(key).inserted { images.append(u) }
        }
        print("\(urls.count) images, \(images.count) distinct")
        var style = OverlayStyle()
        style.showBoxes = false; style.showText = true; style.autoFont = true; style.manualFont = ""
        var tsv = "image\tpixels\tword\tmatch\tlineH\tinkOverVisionH\tedge\tblur\tsizePt\tspacingPt\tdetected\tstandIn\ttop3\tsimilarity\tinverted\twholeLineBox\tsharpen\n"
        for (n, url) in images.enumerated() {
            let path = url.path, name = url.deletingPathExtension().lastPathComponent
            guard let page = try? RecognizedPage(at: url), let px = imagePixelSize(at: path) else { continue }
            let lines = page.allTextBoxes
            let words = testWords(lines, pixelHeight: px.height)
            if words.isEmpty { print("[\(n + 1)/\(images.count)] \(url.lastPathComponent): no usable text"); continue }
            let items = lines.map { (text: $0.text, rect: $0.rect) }
            let ranking = rankFonts(forImage: items, path: path, pixelSize: px).prefix(3)
            let top3 = ranking.map { "\($0.family) \(String(format: "%.2f", $0.score))" }.joined(separator: ", ")
            for word in words {
                let model = PreviewModel()
                final class Flag { var done = false }
                let flag = Flag()
                Task { @MainActor in
                    await model.load(path: path, query: word, searchMode: .phrase, style: style)
                    flag.done = true
                }
                while !flag.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
                let plan = model.plan
                guard !plan.matches.isEmpty,
                      let png = renderExportPNG(path: path, query: word, searchMode: .phrase, style: model.drawingStyle, plan: plan)
                else { continue }
                for (i, m) in plan.matches.enumerated().prefix(2) {
                    let ink = plan.ink[safe: i] ?? nil
                    let ratio = ink.map { $0.rect.height / m.rect.height } ?? 0
                    let sim = similarity(path: path, rendered: png, in: m.rect, pixelSize: px)
                    // Dark text on light in the original, versus what was drawn.
                    let drawnStyle = model.drawingStyle
                    let inkColor = (drawnStyle.autoTextColor ? ink?.color : nil) ?? Color(hex: drawnStyle.textHex) ?? .black
                    let bgColor = (drawnStyle.autoBg ? plan.bgColors[safe: i] ?? nil : nil) ?? Color(hex: drawnStyle.bgHex) ?? .white
                    let drawnDark = luminance(inkColor) < luminance(bgColor)
                    let inverted = originalTextIsDark(path: path, in: m.rect, pixelSize: px).map { $0 != drawnDark } ?? false
                    // Vision gave a word inside a longer line that whole line's box.
                    let line = lines.first { $0.rect.intersects(m.rect) && $0.text.localizedCaseInsensitiveContains(m.text) }
                    let wholeLine = line.map { l in
                        Double(m.text.count) < 0.6 * Double(l.text.count) && m.rect.width > 0.9 * l.rect.width
                    } ?? false
                    tsv += [url.lastPathComponent, "\(Int(px.width))x\(Int(px.height))", word, m.text,
                            String(format: "%.0f", m.rect.height * px.height), String(format: "%.2f", ratio),
                            String(format: "%.2f", ink?.edgeRise ?? 0), String(format: "%.2f", plan.smoothness[safe: i] ?? 0),
                            String(format: "%.1f", (plan.fontSizes[safe: i] ?? 0) / plan.imageScale),
                            String(format: "%.2f", (plan.trackings[safe: i] ?? 0) / plan.imageScale),
                            (model.detections[safe: i] ?? nil)?.family ?? "-",
                            (model.detections[safe: i] ?? nil)?.standsInForSystemFont == true ? "yes" : "no",
                            top3, String(format: "%.3f", sim), inverted ? "yes" : "no", wholeLine ? "yes" : "no",
                            String(format: "%.2f", plan.sharpness[safe: i] ?? 1)]
                        .joined(separator: "\t") + "\n"
                    if let side = sideBySide(path: path, rendered: png, around: ink?.rect ?? m.rect, pixelSize: px) {
                        let safeWord = word.replacingOccurrences(of: "/", with: "-")
                        try? side.write(to: out.appendingPathComponent("\(name)--\(safeWord)-\(i + 1).png"))
                    }
                }
            }
            print("[\(n + 1)/\(images.count)] \(url.lastPathComponent): \(words.joined(separator: ", ")) -> \(top3.isEmpty ? "no ranking" : top3)")
        }
        try? tsv.write(to: out.appendingPathComponent("survey.tsv"), atomically: true, encoding: .utf8)
    }

    /// Up to two words from the image's own text: the longest word on the tallest line, and the
    /// longest on a line of middling height — big display text and ordinary body text.
    static func testWords(_ lines: [TextMatch], pixelHeight: CGFloat) -> [String] {
        func words(_ t: String) -> [String] {
            t.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 }
        }
        let usable = lines.filter { !words($0.text).isEmpty }.sorted { $0.rect.height > $1.rect.height }
        guard let tallest = usable.first else { return [] }
        var picks = [words(tallest.text).max { $0.count < $1.count }!]
        if usable.count > 2 {
            let mid = usable[usable.count / 2]
            if let w = words(mid.text).max(by: { $0.count < $1.count }), !picks.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) {
                picks.append(w)
            }
        }
        return picks
    }

    /// How alike the original and the render are over a match's box (1 = identical), as the
    /// normalised correlation of their brightness — how well the redrawn word stands in for the
    /// one it covers.
    static func similarity(path: String, rendered: Data, in rect: CGRect, pixelSize: CGSize) -> Double {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let a = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let rs = CGImageSourceCreateWithData(rendered as CFData, nil),
              let b = CGImageSourceCreateImageAtIndex(rs, 0, nil) else { return 0 }
        let W = pixelSize.width, H = pixelSize.height
        let r = CGRect(x: rect.minX * W, y: (1 - rect.maxY) * H, width: rect.width * W, height: rect.height * H).integral
        guard let ca = a.cropping(to: r), let cb = b.cropping(to: r) else { return 0 }
        func gray(_ img: CGImage) -> [Double] {
            let w = img.width, h = img.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return [] }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
            return (0..<(w * h)).map { Double(p[$0]) }
        }
        let x = gray(ca), y = gray(cb)
        guard x.count == y.count, !x.isEmpty else { return 0 }
        let n = Double(x.count), mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for k in x.indices { let p = x[k] - mx, q = y[k] - my; sxy += p * q; sxx += p * p; syy += q * q }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0
    }

    static func luminance(_ c: Color) -> Double {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * n.redComponent + 0.7152 * n.greenComponent + 0.0722 * n.blueComponent
    }

    /// Whether the text in `rect` is darker than what surrounds it, judged from the original: the
    /// pixels inside the box that differ most from the ring just outside it are the letters.
    /// nil when there is too little contrast to say.
    static func originalTextIsDark(path: String, in rect: CGRect, pixelSize: CGSize) -> Bool? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let W = pixelSize.width, H = pixelSize.height, pad: CGFloat = 3
        let box = CGRect(x: rect.minX * W, y: (1 - rect.maxY) * H, width: rect.width * W, height: rect.height * H).integral
        let outer = box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard let crop = img.cropping(to: outer) else { return nil }
        let w = crop.width, h = crop.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
        let inset = Int(pad)
        var ring: [Double] = [], core: [Double] = []
        for y in 0..<h { for x in 0..<w {
            let v = Double(p[y * w + x])
            if x < inset || y < inset || x >= w - inset || y >= h - inset { ring.append(v) } else { core.append(v) }
        } }
        guard !ring.isEmpty, !core.isEmpty else { return nil }
        let bg = ring.sorted()[ring.count / 2]
        let far = core.sorted { abs($0 - bg) > abs($1 - bg) }.prefix(max(1, core.count / 10))
        let ink = far.reduce(0, +) / Double(far.count)
        guard abs(ink - bg) > 25 else { return nil }
        return ink < bg
    }
}
