import AppKit
import SwiftUI
import CryptoKit
import CoreText
import OCRSearchCore

/// `OCRSearchApp --selftest <imagesDir> <outDir>`: renders a fixed set of exports without opening
/// any window, and writes every value the overlay is built from — matches, sampled colours, ink,
/// detected font, sizes, spacing, smoothness — next to them. Run it before and after a change and
/// compare the two directories with Scripts/golden-check.sh: identical output means font
/// detection, layout and rendering were not affected.
///
/// Every image is also loaded through PreviewModel, as the preview window does, and exported
/// from there; that PNG must be byte-identical to the batch export's, or the run fails.
///
/// Styles are built here rather than read from UserDefaults, so the result does not depend on
/// what the app happens to have saved. The watermark follows its switch, as exports do.
@MainActor enum SelfTest {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest"), a.count > i + 2 else { return }
        guard legacyStyleDecodes() else { print("FAILED: a saved style from an earlier version no longer loads"); exit(1) }
        guard fontDetectionHolds(images: URL(fileURLWithPath: a[i + 1])) else { exit(1) }
        guard weightBoostRuleHolds() else { exit(1) }
        run(images: URL(fileURLWithPath: a[i + 1]), out: URL(fileURLWithPath: a[i + 2]))
        exit(0)
    }

    /// Font detection against what is known about the test images: iPhone images (IMG_*.PNG)
    /// are set in SF Pro Text, so it must rank first on every one of them, and be reported as
    /// systemFontReplacement. Every image's winner and score is printed for the log.
    static func fontDetectionHolds(images: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? [])
            .filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        let expected = NSFontManager.shared.availableFontFamilies.contains("SF Pro Text") ? "SF Pro Text" : nil
        var screenshots = 0, wrong: [String] = []
        for name in names {
            let path = images.appendingPathComponent(name).path
            guard let page = try? RecognizedPage(at: URL(fileURLWithPath: path)),
                  let px = imagePixelSize(at: path) else { continue }
            let items = page.allTextBoxes.map { (text: $0.text, rect: $0.rect) }
            let ranking = rankFonts(forImage: items, path: path, pixelSize: px)
            let detection = detectedFont(forImage: items, path: path, pixelSize: px)
            let reported = detection?.family
            let top = ranking.prefix(3).map { "\($0.family) \(String(format: "%.3f", $0.score))" }.joined(separator: ", ")
            print("font \(name): \(top) -> \(reported ?? "no match")")
            guard name.hasPrefix("IMG_"), name.lowercased().hasSuffix(".png") else { continue }
            screenshots += 1
            let winner = ranking.first?.family
            let right = expected.map { winner == $0 } ?? winner.map(isSystemFont) ?? false
            if !right || reported != systemFontReplacement || detection?.standsInForSystemFont != true {
                wrong.append("\(name): ranked \(winner ?? "nothing") first, reported \(reported ?? "no match")")
            }
        }
        print("font detection: \(screenshots - wrong.count)/\(screenshots) screenshots ranked \(expected ?? "an SF family") first and reported \(systemFontReplacement)")
        if !wrong.isEmpty { print("FONT DETECTION FAILED:\n  " + wrong.joined(separator: "\n  ")) }
        return wrong.isEmpty
    }

    /// The heavier weight applies only where Noto Sans stands in for a detected SF font: not when
    /// Noto Sans is detected in its own right, not when it (or anything) is picked by hand, and not
    /// with matching off. And it must actually raise Noto Sans's weight axis, regular and bold.
    static func weightBoostRuleHolds() -> Bool {
        let standIn = DetectedFont(family: systemFontReplacement, standsInForSystemFont: true)
        let genuine = DetectedFont(family: systemFontReplacement, standsInForSystemFont: false)
        var auto = OverlayStyle(); auto.autoFont = true
        var off = auto; off.autoFont = false
        var picked = auto; picked.manualFont = systemFontReplacement
        let rules: [(String, CGFloat, CGFloat)] = [
            ("stand-in for SF", PlanStage.weightBoost(for: auto, detected: standIn), systemFontReplacementWeightBoost),
            ("Noto Sans detected itself", PlanStage.weightBoost(for: auto, detected: genuine), 1),
            ("matching off", PlanStage.weightBoost(for: off, detected: standIn), 1),
            ("Noto Sans picked by hand", PlanStage.weightBoost(for: picked, detected: standIn), 1),
            ("nothing detected", PlanStage.weightBoost(for: auto, detected: nil), 1),
        ]
        var ok = true
        for (name, got, want) in rules where got != want {
            print("FAILED weight rule, \(name): \(got), expected \(want)"); ok = false
        }
        let wght = NSNumber(value: 0x77676874)
        func weight(_ f: NSFont) -> Double? { ((CTFontCopyVariation(f as CTFont) as? [NSNumber: Any])?[wght] as? NSNumber)?.doubleValue }
        for (bold, from) in [(false, 400.0), (true, 700.0)] {
            guard let f = NSFontManager.shared.font(withFamily: systemFontReplacement, traits: bold ? .boldFontMask : [],
                                                    weight: 5, size: 40) else { print("FAILED: no \(systemFontReplacement)"); return false }
            let got = weight(heavier(f, by: systemFontReplacementWeightBoost)) ?? 0
            // Noto Sans's weight axis stops at 900.
            let expected = min(from * Double(systemFontReplacementWeightBoost), 900)
            if abs(got - expected) > 0.5 {
                print("FAILED: \(systemFontReplacement) \(bold ? "bold" : "regular") weight \(got), expected \(expected)"); ok = false
            }
        }
        if ok {
            let r = min(400 * Double(systemFontReplacementWeightBoost), 900), b = min(700 * Double(systemFontReplacementWeightBoost), 900)
            print("weight boost: only for the SF stand-in, \(systemFontReplacement) 400->\(Int(r)) and 700->\(Int(b))")
        }
        return ok
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
        var previewChecked = 0, previewMismatches: [String] = []
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
                let png = renderExportPNG(path: p, query: c.query, searchMode: c.mode, style: c.style, plan: plan)
                if let png {
                    try? png.write(to: dir.appendingPathComponent(name + ".png"))
                    entry["pngSHA256"] = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                }
                // Straight in with the case's style, and in with another style first and then
                // switched — which is what exercises re-running only the stages a change affects.
                for restyled in [false, true] {
                    let (previewPlan, previewStyle, problems) = loadInPreview(path: p, c, restyled: restyled)
                    let fromPreview = renderExportPNG(path: p, query: c.query, searchMode: c.mode,
                                                      style: previewStyle, plan: previewPlan)
                    previewChecked += 1
                    let label = "\(c.name) \(name)\(restyled ? " (restyled)" : "")"
                    if fromPreview != png { previewMismatches.append("\(label): export differs") }
                    previewMismatches += problems.map { "\(label): \($0)" }
                }
                report.append(entry)
                print("\(c.name) \(name): \(plan.matches.count) matches, font \(plan.matchedFonts.first.flatMap { $0 } ?? "-")")
            }
            if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: dir.appendingPathComponent("plan.json"))
            }
        }
        print("preview runs: \(previewChecked), problems: \(previewMismatches.count)")
        if !previewMismatches.isEmpty {
            print("PREVIEW MISMATCH:\n  " + previewMismatches.joined(separator: "\n  "))
            exit(1)
        }
    }

    /// Loads `path` the way the preview window does and returns what its Export would render,
    /// plus any step at which its cached fitting disagreed with fitting afresh.
    ///
    /// With `restyled`, it loads with a different search and look first — the opposite font choices, spacing
    /// and switches — then walks back to the case's style one field at a time, and finally flips
    /// each field on its own and back, as editing the style panel would. After every step the
    /// model's family, sizes and spacing must equal the stages run from scratch on its own scan:
    /// a stage it wrongly skipped shows up there even when a later step would have hidden it.
    /// Spins the main run loop while waiting, since the model's work hops back to the main actor.
    static func loadInPreview(path: String, _ c: Case, restyled: Bool) -> (RenderPlan, OverlayStyle, [String]) {
        final class State { var done = false; var problems: [String] = [] }
        let model = PreviewModel(), state = State()
        let target = c.style
        var first = target
        if restyled {
            first.showBoxes.toggle(); first.showText = true; first.autoFont.toggle()
            first.manualFont = target.manualFont.isEmpty ? "Georgia" : ""
            first.weight = target.weight == .bold ? .regular : .bold
            first.design = target.design == .serif ? .system : .serif
            first.kerning.toggle(); first.manualSize = target.manualSize > 0 ? 0 : 20
            first.manualTracking = target.manualTracking == nil ? 1 : nil
        }
        let fields: [(String, (inout OverlayStyle) -> Void, (inout OverlayStyle) -> Void)] = [
            ("kerning", { $0.kerning.toggle() }, { $0.kerning = target.kerning }),
            ("manualTracking", { $0.manualTracking = $0.manualTracking == nil ? 1 : nil }, { $0.manualTracking = target.manualTracking }),
            ("manualSize", { $0.manualSize = $0.manualSize > 0 ? 0 : 20 }, { $0.manualSize = target.manualSize }),
            ("weight", { $0.weight = $0.weight == .bold ? .regular : .bold }, { $0.weight = target.weight }),
            ("design", { $0.design = $0.design == .serif ? .system : .serif }, { $0.design = target.design }),
            ("autoFont", { $0.autoFont.toggle() }, { $0.autoFont = target.autoFont }),
            ("manualFont", { $0.manualFont = $0.manualFont.isEmpty ? "Georgia" : "" }, { $0.manualFont = target.manualFont }),
            ("switches", { $0.showBoxes.toggle(); $0.showText.toggle() }, { $0.showBoxes = target.showBoxes; $0.showText = target.showText }),
        ]
        func check(_ s: OverlayStyle, _ step: String) {
            let family = PlanStage.family(for: s) { model.detection?.family }
            let boost = PlanStage.weightBoost(for: s, detected: model.detection)
            let sizes = PlanStage.fitSizes(matches: model.matches, ink: model.ink, family: family,
                                           weightBoost: boost, style: s, pixelSize: model.pixelSize)
            let trackings = PlanStage.fitTrackings(matches: model.matches, ink: model.ink, sizes: sizes,
                                                   family: family, weightBoost: boost, style: s,
                                                   pixelSize: model.pixelSize, imageScale: model.imageScale)
            // Within a millionth of a point: CoreText's measurements wobble in the ninth digit from
            // one call to the next for the same font and text. A stale value is off by far more.
            func same(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
                a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
            }
            var wrong: [String] = []
            if model.family != family { wrong.append("family") }
            if model.weightBoost != boost { wrong.append("weight") }
            if !same(model.fontSizes, sizes) { wrong.append("sizes") }
            if !same(model.trackings, trackings) { wrong.append("spacing") }
            if model.drawingStyle != s { wrong.append("style") }
            if !wrong.isEmpty { state.problems.append("after \(step): stale \(wrong.joined(separator: ", "))") }
        }
        Task { @MainActor in
            // Restyled runs also start from another search and change to the case's, as typing in
            // the window's search field does — matches found again from the page already read.
            await model.load(path: path, query: restyled ? "Settings" : c.query,
                             searchMode: restyled ? .words : c.mode, style: first)
            check(first, "load")
            if restyled {
                await model.search(query: c.query, searchMode: c.mode)
                check(first, "searching again")
                var s = first
                for (name, _, restore) in fields { restore(&s); await model.update(s); check(s, "setting \(name)") }
                for (name, flip, restore) in fields {
                    flip(&s); await model.update(s); check(s, "flipping \(name)")
                    restore(&s); await model.update(s); check(s, "restoring \(name)")
                }
            }
            state.done = true
        }
        while !state.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
        return (model.plan, model.drawingStyle, state.problems)
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
