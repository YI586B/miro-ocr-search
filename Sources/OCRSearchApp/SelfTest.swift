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
        guard ownLookRulesHold() else { exit(1) }
        guard edgeCalibrationHolds() else { exit(1) }
        guard exportSizeHolds(images: URL(fileURLWithPath: a[i + 1])) else { exit(1) }
        guard offsetHolds(images: URL(fileURLWithPath: a[i + 1])) else { exit(1) }
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

    /// An image keeps a look of its own only while it differs from the defaults: opening one, or
    /// switching the app-wide overlay, Boxes or Text, must not freeze a copy of the defaults onto
    /// it. Checked against a throwaway preferences store, not the app's own.
    static func ownLookRulesHold() -> Bool {
        let suite = "ocrsearch-selftest-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: suite) else { return false }
        defer { d.removePersistentDomain(forName: suite) }
        let path = "/tmp/example.png"
        var problems: [String] = []
        let defaults = OverlayStyle.current(d)
        defaults.keep(for: path, d)
        if OverlayStyle.savedCount(d) != 0 { problems.append("a look equal to the defaults was saved") }
        var switched = defaults; switched.showBoxes.toggle(); switched.show.toggle()
        switched.keep(for: path, d)
        if OverlayStyle.savedCount(d) != 0 { problems.append("switching Boxes or the overlay made the look the image's own") }
        var changed = defaults; changed.opacity = 0.5
        changed.keep(for: path, d)
        if OverlayStyle.savedCount(d) != 1 || OverlayStyle.forImage(path, d).opacity != 0.5 { problems.append("a changed look was not kept") }
        defaults.keep(for: path, d)
        if OverlayStyle.savedCount(d) != 0 { problems.append("changing back did not forget the image's look") }
        changed.keep(for: path, d); OverlayStyle.clearAll(d)
        if OverlayStyle.savedCount(d) != 0 { problems.append("forgetting all left some") }
        for p in problems { print("FAILED own look: \(p)") }
        if problems.isEmpty { print("own look: kept only while it differs from the defaults") }
        return problems.isEmpty
    }

    /// A moved image (OverlayStyle.offsetX/Y), exported with no highlights and so no watermark: every
    /// pixel is the original's from (x - dx, y - dy), and where that falls outside the image it is
    /// black. Moved 40px left and 12px down, the right 40 columns and top 12 rows are black.
    static func offsetHolds(images: URL) -> Bool {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).sorted()
        guard let name = names.first(where: { $0.hasPrefix("IMG_") && $0.hasSuffix(".PNG") }) else { return true }
        let path = images.appendingPathComponent(name).path
        var plain = OverlayStyle(); plain.show = false
        var moved = plain; moved.offsetX = -40; moved.offsetY = 12
        func pixels(_ png: Data?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let png, let cg = NSBitmapImageRep(data: png)?.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            guard let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (cg.width, cg.height, px)
        }
        guard let a = pixels(renderExportPNG(path: path, query: "", searchMode: .phrase, style: plain)),
              let b = pixels(renderExportPNG(path: path, query: "", searchMode: .phrase, style: moved)),
              a.w == b.w, a.h == b.h else { print("FAILED offset: did not render"); return false }
        var wrong = 0
        for y in 0..<b.h { for x in 0..<b.w {
            let sx = x + 40, sy = y - 12          // where this pixel came from
            let i = (y * b.w + x) * 4
            let want: [UInt8] = (sx < a.w && sy >= 0) ? Array(a.px[((sy * a.w + sx) * 4)..<((sy * a.w + sx) * 4 + 3)]) : [0, 0, 0]
            if Array(b.px[i..<(i + 3)]) != want { wrong += 1 }
        } }
        if wrong > 0 { print("FAILED offset: \(wrong) pixels are not the original moved 40px left and 12px down"); return false }
        print("offset (\(name)): moved 40px left and 12px down exactly, the space left black")
        return true
    }

    /// Settings ▸ Export size: at 100% and at 112.44%, the export is that size, and its watermark
    /// is the original image's badge at every size (watermarkPixelSize of the image, not of the
    /// export), 20px from the export's right and bottom edges. The
    /// badge is found as the pixels that change when only the watermark is added.
    static func exportSizeHolds(images: URL) -> Bool {
        guard Watermark.isOn else { print("export size: skipped, the watermark is switched off"); return true }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).sorted()
        guard let name = names.first(where: { $0.hasPrefix("IMG_") && $0.hasSuffix(".PNG") }) else {
            print("export size: skipped, no IMG_*.PNG"); return true
        }
        let path = images.appendingPathComponent(name).path
        var marked = OverlayStyle(); marked.showBoxes = false; marked.showText = false
        var plain = marked; plain.show = false
        func pixels(_ png: Data?) -> (w: Int, h: Int, px: [UInt8])? {
            guard let png, let cg = NSBitmapImageRep(data: png)?.cgImage else { return nil }
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            guard let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (cg.width, cg.height, px)
        }
        var ok = true, report: [String] = []
        for percent in [100.0, 112.44] {
            let scale = CGFloat(percent / 100)
            guard let a = pixels(renderExportPNG(path: path, query: "", searchMode: .phrase, style: marked, scale: scale)),
                  let b = pixels(renderExportPNG(path: path, query: "", searchMode: .phrase, style: plain, scale: scale)),
                  a.w == b.w, a.h == b.h else { print("FAILED export size: \(percent)% did not render"); return false }
            guard let cg = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
                    .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return false }
            let want = ExportSize.outputSize(width: cg.width, height: cg.height, scale: scale)
            if (a.w, a.h) != want {
                print("FAILED export size: \(percent)% is \(a.w)x\(a.h), expected \(want.width)x\(want.height)"); ok = false
            }
            // Bounding box of the pixels the watermark changed, in top-left coordinates.
            var minX = a.w, minY = a.h, maxX = -1, maxY = -1
            for y in 0..<a.h { for x in 0..<a.w {
                let i = (y * a.w + x) * 4
                if a.px[i] != b.px[i] || a.px[i + 1] != b.px[i + 1] || a.px[i + 2] != b.px[i + 2] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            } }
            let badge = watermarkPixelSize(forImage: CGSize(width: cg.width, height: cg.height))
            let got = (w: maxX - minX + 1, h: maxY - minY + 1, right: a.w - 1 - maxX, bottom: a.h - 1 - maxY)
            if maxX < 0 || abs(got.w - Int(badge.width)) > 1 || abs(got.h - Int(badge.height)) > 1
                || abs(got.right - Int(watermarkRightMargin)) > 1 || abs(got.bottom - Int(watermarkBottomMargin)) > 1 {
                print("FAILED export size: \(percent)% badge \(got.w)x\(got.h) at \(got.right)/\(got.bottom)px, expected \(Int(badge.width))x\(Int(badge.height)) at 20/20")
                ok = false
            }
            report.append("\(ExportSize.label(percent)) \(a.w)x\(a.h) badge \(got.w)x\(got.h)")
        }
        if ok { print("export size (\(name)): " + report.joined(separator: ", ")) }
        return ok
    }

    /// How soft our own drawing is, measured as the originals are, across families and sizes —
    /// what drawnEdgeRise is set from — and whether sharpening by a factor narrows it by that
    /// factor. Printed for the log; fails if either is off by more than it should be.
    static func edgeCalibrationHolds() -> Bool {
        let samples = ["Screen Active", "Background", "observability", "The world is watching"]
        var plain: [CGFloat] = [], ok = true
        for family in ["Noto Sans", "Helvetica Neue", "Georgia", "Palatino"] {
            for size in [14.0, 22.0, 40.0] {
                guard let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: CGFloat(size)) else { continue }
                for t in samples { if let r = drawnEdgeRise(of: t, font: f) { plain.append(r) } }
            }
        }
        let mean = plain.reduce(0, +) / CGFloat(max(plain.count, 1))
        let sorted = plain.sorted()
        print(String(format: "edge: our drawing rises over %.3f px (range %.3f-%.3f over %d samples); constant is %.3f",
                     mean, sorted.first ?? 0, sorted.last ?? 0, plain.count, drawnEdgeRise))
        if abs(mean - drawnEdgeRise) > 0.08 { print("FAILED edge: drawnEdgeRise is off the measured drawing"); ok = false }
        // Sharpening has to narrow the edge, more for a larger factor. Not by the factor itself:
        // at a pixel or so wide there is little ramp to steepen, which is why fitEdges searches for
        // the factor rather than computing it.
        if let f = NSFontManager.shared.font(withFamily: "Noto Sans", traits: [], weight: 5, size: 22) {
            var previous = drawnEdgeRise(of: "Background", font: f) ?? 0
            let base = previous
            for factor in [1.15, 1.3, maximumSharpening] as [CGFloat] {
                let sharp = drawnEdgeRise(of: "Background", font: f, sharpen: factor) ?? 0
                print(String(format: "edge: sharpen x%.2f takes %.3f px to %.3f px", factor, base, sharp))
                if sharp >= previous { print("FAILED edge: sharpening did not narrow the edge further"); ok = false }
                previous = sharp
            }
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
        manual.kerning = false; manual.weight = .bold; manual.autoWeight = false; manual.italic = true
        manual.autoBg = false; manual.bgHex = "#EEEEEE"; manual.autoTextColor = false; manual.textHex = "#112233"
        var designed = OverlayStyle()
        designed.showBoxes = false; designed.autoFont = false; designed.design = .serif; designed.weight = .medium; designed.autoWeight = false
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
            first.weight = target.weight == .bold ? .regular : .bold; first.autoWeight.toggle()
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
            ("autoWeight", { $0.autoWeight.toggle() }, { $0.autoWeight = target.autoWeight }),
            ("manualFont", { $0.manualFont = $0.manualFont.isEmpty ? "Georgia" : "" }, { $0.manualFont = target.manualFont }),
            ("switches", { $0.showBoxes.toggle(); $0.showText.toggle() }, { $0.showBoxes = target.showBoxes; $0.showText = target.showText }),
        ]
        func check(_ s: OverlayStyle, _ step: String) {
            let found = model.matches.indices.map { model.detections[safe: $0] ?? nil }
            let family = found.map { d in PlanStage.family(for: s) { d?.family } }
            let boost = found.map { PlanStage.weightBoost(for: s, detected: $0) }
            let weights = PlanStage.fitWeights(path: path, matches: model.matches, ink: model.ink, families: family,
                                               weightBoosts: boost, style: s)
            let sizes = PlanStage.fitSizes(matches: model.matches, ink: model.ink, families: family,
                                           weightBoosts: boost, weights: weights, style: s, pixelSize: model.pixelSize)
            let trackings = PlanStage.fitTrackings(matches: model.matches, ink: model.ink, sizes: sizes,
                                                   families: family, weightBoosts: boost, weights: weights, style: s,
                                                   pixelSize: model.pixelSize, imageScale: model.imageScale)
            // Within a millionth of a point: CoreText's measurements wobble in the ninth digit from
            // one call to the next for the same font and text. A stale value is off by far more.
            func same(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
                a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
            }
            var wrong: [String] = []
            if model.families != family { wrong.append("family") }
            if model.weightBoosts != boost { wrong.append("weight boost") }
            if model.weights != weights { wrong.append("weights") }
            if !same(model.fontSizes, sizes) { wrong.append("sizes") }
            if !same(model.trackings, trackings) { wrong.append("spacing") }
            let edges = PlanStage.fitEdges(matches: model.matches, ink: model.ink, sizes: sizes, families: family,
                                           weightBoosts: boost, weights: weights,
                                           standIns: found.map { PlanStage.standsIn(for: s, detected: $0) },
                                           style: s, imageScale: model.imageScale)
            for (i, d) in found.enumerated() where PlanStage.standsIn(for: s, detected: d) {
                if (model.smoothness[safe: i] ?? 0) != 0 || (model.sharpness[safe: i] ?? 1) != 1 { wrong.append("stand-in edges not 0") }
            }
            if !same(model.smoothness, edges.blur) || !same(model.sharpness, edges.sharpen) { wrong.append("edges") }
            if model.drawingStyle != s { wrong.append("style") }
            if !wrong.isEmpty { state.problems.append("after \(step): stale \(wrong.joined(separator: ", "))") }
        }
        Task { @MainActor in
            // Restyled runs also start from another search and change to the case's, as typing in
            // the window's search field does — matches found again from the page already read.
            await model.load(path: path, query: restyled ? "Settings" : c.query,
                             searchMode: restyled ? .words : c.mode, style: first)
            check(first, "load")
            // Per-block detection, straight after loading: the same answers a fresh detector gives.
            if !restyled, !model.detections.isEmpty, let page = try? RecognizedPage(at: URL(fileURLWithPath: path)) {
                let fresh = BlockFontDetector(page: page, path: path, pixelSize: model.pixelSize).detect(model.matches)
                if fresh != model.detections { state.problems.append("after load: per-block detection differs from a fresh detector") }
            }
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
            "sharpness": plan.sharpness.map(Double.init),
        ]
    }
}
