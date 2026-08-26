import AppKit
import SwiftUI
import CryptoKit
import OCRSearchCore

/// `OCRSearchApp --selftest <imagesDir> <outDir>`: renders a fixed set of exports without opening
/// any window, and writes every value the overlay is built from — matches, sampled colours, ink,
/// detected font, sizes, spacing, smoothness — next to them. Run it before and after a change and
/// compare the two directories with Scripts/golden-check.sh: identical output means font
/// detection, layout and rendering were not affected.
///
/// Styles are built here rather than read from UserDefaults, so the result does not depend on
/// what the app happens to have saved. The watermark follows its switch, as exports do.
enum SelfTest {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest"), a.count > i + 2 else { return }
        guard legacyStyleDecodes() else { print("FAILED: a saved style from an earlier version no longer loads"); exit(1) }
        run(images: URL(fileURLWithPath: a[i + 1]), out: URL(fileURLWithPath: a[i + 2]))
        exit(0)
    }

    /// A per-image style as saved by earlier versions — with the old Boxes-or-Text `mode` and
    /// font design and weight as plain strings — must still load, or every image's saved look
    /// would silently fall back to the defaults.
    static func legacyStyleDecodes() -> Bool {
        let json = ##"{"show":true,"mode":"text","boxHex":"#FFD60A","opacity":0.5,"outline":false,"##
            + ##""textHex":"#112233","autoTextColor":false,"bgHex":"#EEEEEE","autoBg":true,"design":"serif","##
            + ##""weight":"bold","autoFont":true,"manualFont":"Helvetica","manualTracking":0.3,"kerning":false,"##
            + ##""manualSmoothness":0.4,"manualSize":14,"italic":true}"##
        guard let s = try? JSONDecoder().decode(OverlayStyle.self, from: Data(json.utf8)) else { return false }
        return s.design == .serif && s.weight == .bold && s.opacity == 0.5 && !s.outline
            && s.textHex == "#112233" && !s.autoTextColor && s.manualFont == "Helvetica"
            && s.manualTracking == 0.3 && !s.kerning && s.manualSmoothness == 0.4 && s.manualSize == 14
            && s.italic && s.autoFont
    }

    struct Case {
        let name: String
        let query: String
        let mode: SearchMode
        let style: OverlayStyle
    }

    static var cases: [Case] {
        var boxes = OverlayStyle(); boxes.showText = false
        var textSystem = OverlayStyle(); textSystem.showBoxes = false; textSystem.autoFont = false
        var textAuto = OverlayStyle(); textAuto.showBoxes = false; textAuto.autoFont = true
        var both = OverlayStyle(); both.autoFont = true
        var manual = OverlayStyle()
        manual.showBoxes = false; manual.autoFont = false; manual.manualFont = "Helvetica"
        manual.manualSize = 14; manual.manualTracking = 0.3; manual.manualSmoothness = 0.4
        manual.kerning = false; manual.weight = .bold; manual.italic = true
        manual.autoBg = false; manual.bgHex = "#EEEEEE"; manual.autoTextColor = false; manual.textHex = "#112233"
        var designed = OverlayStyle()
        designed.showBoxes = false; designed.autoFont = false; designed.design = .serif; designed.weight = .medium
        designed.outline = false; designed.opacity = 0.5; designed.boxHex = "#33AAFF"
        var boxesStyled = designed; boxesStyled.showBoxes = true; boxesStyled.showText = false
        return [
            Case(name: "boxes", query: "Screen Active", mode: .phrase, style: boxes),
            Case(name: "boxes-styled", query: "New Relic", mode: .phrase, style: boxesStyled),
            Case(name: "text-system", query: "Screen Active", mode: .phrase, style: textSystem),
            Case(name: "text-auto", query: "Screen Active", mode: .phrase, style: textAuto),
            Case(name: "text-auto-relic", query: "New Relic", mode: .phrase, style: textAuto),
            Case(name: "both-auto", query: "Screen Active", mode: .phrase, style: both),
            Case(name: "both-words", query: "Screen Time", mode: .words, style: both),
            Case(name: "text-manual", query: "Screen Active", mode: .phrase, style: manual),
            Case(name: "text-serif", query: "New Relic", mode: .phrase, style: designed),
        ]
    }

    static func run(images: URL, out: URL) {
        let fm = FileManager.default
        let paths = ((try? fm.contentsOfDirectory(atPath: images.path)) ?? [])
            .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { images.appendingPathComponent($0).path }
        for c in cases {
            let dir = out.appendingPathComponent(c.name)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var report: [[String: Any]] = []
            for p in paths {
                let plan = RenderPlan.build(path: p, query: c.query, searchMode: c.mode, style: c.style)
                let name = (p as NSString).lastPathComponent
                var entry = describe(plan)
                entry["image"] = name
                if let png = renderExportPNG(path: p, query: c.query, searchMode: c.mode, style: c.style, plan: plan) {
                    try? png.write(to: dir.appendingPathComponent(name + ".png"))
                    entry["pngSHA256"] = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                }
                report.append(entry)
                print("\(c.name) \(name): \(plan.matches.count) matches, font \(plan.matchedFonts.first.flatMap { $0 } ?? "-")")
            }
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: dir.appendingPathComponent("plan.json"))
            }
        }
    }

    /// The plan as plain JSON values, at full precision, so a difference in the last digit shows.
    static func describe(_ plan: RenderPlan) -> [String: Any] {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }
        func color(_ c: Color?) -> Any {
            guard let c, let n = NSColor(c).usingColorSpace(.sRGB) else { return NSNull() }
            return [n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent].map(Double.init)
        }
        return [
            "pixelSize": [Double(plan.pixelSize.width), Double(plan.pixelSize.height)],
            "imageScale": Double(plan.imageScale),
            "matches": plan.matches.map { ["text": $0.text, "rect": rect($0.rect)] as [String: Any] },
            "bgColors": plan.bgColors.map { color($0) },
            "ink": plan.ink.map { s -> Any in
                guard let s else { return NSNull() }
                return ["rect": rect(s.rect), "color": color(s.color), "edgeRise": Double(s.edgeRise)] as [String: Any]
            },
            "matchedFonts": plan.matchedFonts.map { $0 as Any? ?? NSNull() },
            "fontSizes": plan.fontSizes.map(Double.init),
            "trackings": plan.trackings.map(Double.init),
            "smoothness": plan.smoothness.map(Double.init),
        ]
    }
}
