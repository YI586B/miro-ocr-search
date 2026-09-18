import SwiftUI
import AppKit
import OCRSearchCore

/// Persisted highlight look, shared by the Settings window and the preview window's toolbar.
enum HL {
    static let show = "highlightShow"            // overlay on/off
    static let showBoxes = "highlightShowBoxes"  // draw a box over each match
    static let showText = "highlightShowText"    // redraw each match as text
    static let boxHex = "highlightHex"           // box colour (also the text-chip background)
    static let opacity = "highlightOpacity"
    static let outline = "highlightOutline"
    static let textHex = "highlightTextHex"
    static let autoTextColor = "highlightAutoTextColor"  // sample the text's own ink color from the image instead of using textHex
    static let bgHex = "highlightBgHex"          // text-mode background, when auto-match is off or sampling fails
    static let autoBg = "highlightAutoBg"        // sample the background from the image instead of using bgHex
    static let design = "highlightFontDesign"    // default | rounded | serif | monospaced
    static let weight = "highlightFontWeight"    // regular | medium | bold
    static let autoWeight = "highlightAutoWeight"  // pick regular or bold per match from the image instead of using weight
    static let autoFont = "highlightAutoFont"    // auto-match an installed font instead of using design
    static let manualFont = "highlightManualFont"  // overrides the auto-detected family; "" = use it as detected
    static let manualSize = "highlightManualSize"  // fixed size for every match, in image pixels; 0 = auto-fit
    static let italic = "highlightItalic"          // draw matched words in italic
    static let defaultBox = "#FF1400"
    static let defaultText = "#000000"
    static let defaultBg = "#FFFFFF"

}

/// The system font's design, used when no family is matched or picked. The raw values are what
/// UserDefaults and each image's saved style store, so they must not change.
enum TextDesign: String, Codable, CaseIterable, Sendable {
    case system = "default", rounded, serif, monospaced

    var font: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
    var label: String { self == .system ? "System" : rawValue.capitalized }
}

/// The weight matches are redrawn in. Raw values are stored, as for TextDesign.
enum TextWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, bold

    var font: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }
    var label: String { rawValue.capitalized }
}

// MARK: - style snapshot

/// The persisted overlay look (the HL.* defaults), snapshotted into a plain value so a render can
/// run off the main actor without reading @AppStorage — which is a SwiftUI view-side wrapper and
/// isn't available to the export path, whether that runs from the preview window's Save command
/// or from a batch export with no preview window open at all.
struct OverlayStyle: Sendable, Codable, Equatable {
    /// The one place the defaults are defined. Settings, the menu bar, the preview window and
    /// an untouched install all start from these values.
    static let defaults = OverlayStyle()

    var show = true
    var showBoxes = true
    var showText = true
    var boxHex = HL.defaultBox
    var opacity = 0.0
    var outline = true
    var textHex = HL.defaultText
    var autoTextColor = true
    var bgHex = HL.defaultBg
    var autoBg = true
    var design: TextDesign = .system
    var weight: TextWeight = .regular
    /// Pick regular or bold for each match by comparing both with the original's letters, rather
    /// than drawing every match in `weight` — screenshots mix weights, and a bold heading redrawn
    /// regular stands out. Only where the letters were isolated; elsewhere `weight` applies.
    var autoWeight = true
    var autoFont = true
    var manualFont = ""
    /// Letter spacing, in points, applied on top of what the font does by itself. nil fits it to
    /// each match's measured width — see inkFittedTracking.
    var manualTracking: Double? = nil
    /// Whether the font's own pair kerning is used. Off replaces it with even spacing.
    var kerning: Bool = true
    /// How much the redrawn text is softened, as a Gaussian standard deviation in points. nil
    /// matches each match's own measured edge softness — see smoothnessToMatch.
    var manualSmoothness: Double? = nil
    /// Fixed size for every match, in points — the unit that means the same thing whatever the
    /// image's own resolution is, and independent of how the window happens to be showing it.
    /// 0 = fit each match individually. See RenderPlan.imageScale.
    var manualSize: Double = 0
    var italic = false
    /// Where the original image sits in its own frame, in image pixels (right and down are
    /// positive): set by dragging it in the preview. The frame keeps its size; what is pushed past
    /// the edge is cut off and the space it leaves is black. The highlights move with the image;
    /// the watermark does not. Per image only — never part of the defaults.
    var offsetX = 0.0
    var offsetY = 0.0

    var isOffset: Bool { offsetX != 0 || offsetY != 0 }

    /// Boxes and text are app-wide (see forImage), so they are left out of what an image saves.
    private enum CodingKeys: String, CodingKey {
        case show, boxHex, opacity, outline, textHex, autoTextColor, bgHex, autoBg, design, weight
        case autoWeight, autoFont, manualFont, manualTracking, kerning, manualSmoothness, manualSize, italic
        case offsetX, offsetY
    }

    // MARK: per image
    //
    // The look is stored per image, not once for the app. Every image is different, with
    // its own type sizes and colours, so a font or size that is right for one is usually
    // wrong for the next; sharing one set of values meant tuning an image silently restyled every
    // other one, and there was no way to go back to what a given image looked like. The Settings
    // window still sets the defaults an image starts from.

    private static let store = "imageStyles"
    /// Enough that returning to an image from a session's work still finds its settings, bounded
    /// so the defaults file cannot grow without limit.
    private static let keep = 300

    /// The look for `path`: what was last set for that image, or the defaults if it has none.
    static func forImage(_ path: String, _ d: UserDefaults = .standard) -> OverlayStyle {
        guard let raw = d.dictionary(forKey: store)?[path] as? Data,
              var s = try? JSONDecoder().decode(OverlayStyle.self, from: raw) else { return current(d) }
        // Whether the overlay is on, and boxes or text, are app-wide: they describe how you are
        // looking at whatever is open rather than this image, so a saved copy of them is ignored
        // in favour of the current setting.
        let live = current(d)
        s.show = live.show
        s.showBoxes = live.showBoxes
        s.showText = live.showText
        return s
    }

    func save(for path: String, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        var all = d.dictionary(forKey: Self.store) ?? [:]
        all[path] = data
        // Oldest-first eviction is not worth a timestamp per entry; dropping arbitrary extras once
        // over the cap only costs those images their overrides, and they fall back to the defaults.
        if all.count > Self.keep {
            all = all.prefix(Self.keep).reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        }
        d.set(all, forKey: Self.store)
    }

    static func clear(_ path: String, _ d: UserDefaults = .standard) {
        guard var all = d.dictionary(forKey: store) else { return }
        all[path] = nil
        d.set(all, forKey: store)
    }

    /// Forgets every image's own look, so all of them follow the defaults again.
    static func clearAll(_ d: UserDefaults = .standard) { d.removeObject(forKey: store) }

    /// How many images have a look of their own.
    static func savedCount(_ d: UserDefaults = .standard) -> Int { d.dictionary(forKey: store)?.count ?? 0 }

    /// Whether this look differs from `other` in anything an image keeps for itself — that is,
    /// leaving out the app-wide overlay, Boxes and Text switches.
    func differs(from other: OverlayStyle) -> Bool {
        func own(_ s: OverlayStyle) -> OverlayStyle {
            var s = s; s.show = true; s.showBoxes = true; s.showText = true; return s
        }
        return own(self) != own(other)
    }

    /// Keeps this as `path`'s own look only if it differs from the defaults; otherwise forgets any
    /// saved one, so the image goes on following the defaults as they change.
    ///
    /// Saving on every change used to store a copy of the defaults for every image merely opened.
    /// Those copies then outlived the defaults they were taken from: after the box fill default
    /// went to 0%, images viewed before still drew it at 35%.
    func keep(for path: String, _ d: UserDefaults = .standard) {
        if differs(from: Self.current(d)) { save(for: path, d) } else { Self.clear(path, d) }
    }

    /// Writes this look back as the defaults every image starts from.
    func saveAsDefaults(_ d: UserDefaults = .standard) {
        d.set(show, forKey: HL.show)
        d.set(showBoxes, forKey: HL.showBoxes); d.set(showText, forKey: HL.showText)
        d.set(boxHex, forKey: HL.boxHex); d.set(opacity, forKey: HL.opacity)
        d.set(outline, forKey: HL.outline); d.set(textHex, forKey: HL.textHex)
        d.set(autoTextColor, forKey: HL.autoTextColor); d.set(bgHex, forKey: HL.bgHex)
        d.set(autoBg, forKey: HL.autoBg); d.set(design.rawValue, forKey: HL.design)
        d.set(weight.rawValue, forKey: HL.weight); d.set(autoWeight, forKey: HL.autoWeight)
        d.set(autoFont, forKey: HL.autoFont)
        d.set(manualFont, forKey: HL.manualFont); d.set(manualSize, forKey: HL.manualSize)
        d.set(italic, forKey: HL.italic)
    }

    /// Reads whatever the Settings window and the preview toolbar have persisted. Every lookup
    /// goes through an explicit "is it set at all?" check rather than UserDefaults' zero/false
    /// defaults, so an untouched install exports with the same look it previews with instead of
    /// silently falling back to `false` for every toggle.
    static func current(_ d: UserDefaults = .standard) -> OverlayStyle {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) == nil ? fallback : d.bool(forKey: key)
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            d.object(forKey: key) == nil ? fallback : d.double(forKey: key)
        }
        let def = defaults
        return OverlayStyle(
            show: bool(HL.show, def.show),
            showBoxes: bool(HL.showBoxes, def.showBoxes),
            showText: bool(HL.showText, def.showText),
            boxHex: d.string(forKey: HL.boxHex) ?? def.boxHex,
            opacity: double(HL.opacity, def.opacity),
            outline: bool(HL.outline, def.outline),
            textHex: d.string(forKey: HL.textHex) ?? def.textHex,
            autoTextColor: bool(HL.autoTextColor, def.autoTextColor),
            bgHex: d.string(forKey: HL.bgHex) ?? def.bgHex,
            autoBg: bool(HL.autoBg, def.autoBg),
            design: d.string(forKey: HL.design).flatMap(TextDesign.init(rawValue:)) ?? def.design,
            weight: d.string(forKey: HL.weight).flatMap(TextWeight.init(rawValue:)) ?? def.weight,
            autoWeight: bool(HL.autoWeight, def.autoWeight),
            autoFont: bool(HL.autoFont, def.autoFont),
            manualFont: d.string(forKey: HL.manualFont) ?? def.manualFont,
            manualSize: double(HL.manualSize, def.manualSize),
            italic: bool(HL.italic, def.italic))
    }

    /// Whether any font setting differs from automatic — what resetFontToAutomatic undoes.
    var fontIsOverridden: Bool {
        !manualFont.isEmpty || manualSize > 0 || manualTracking != nil
            || manualSmoothness != nil || !kerning || weight == .bold || !autoWeight || italic
    }

    /// Font, size, spacing and smoothness back to what is matched and fitted from the image,
    /// regular weight, no italic, the font's own kerning.
    mutating func resetFontToAutomatic() {
        manualFont = ""; autoFont = true
        manualSize = 0; manualTracking = nil; manualSmoothness = nil
        kerning = true
        weight = .regular; autoWeight = true; italic = false
    }
}

extension OverlayStyle {
    /// Loads a saved look field by field, keeping the default for any field it does not have, so a
    /// look saved before a setting existed still loads — with the new setting at its default —
    /// instead of failing and dropping the image back to the Settings defaults altogether.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        load(.show, &show); load(.boxHex, &boxHex); load(.opacity, &opacity); load(.outline, &outline)
        load(.textHex, &textHex); load(.autoTextColor, &autoTextColor); load(.bgHex, &bgHex)
        load(.autoBg, &autoBg); load(.design, &design); load(.weight, &weight); load(.autoWeight, &autoWeight)
        load(.autoFont, &autoFont); load(.manualFont, &manualFont); load(.kerning, &kerning)
        load(.manualSize, &manualSize); load(.italic, &italic)
        load(.offsetX, &offsetX); load(.offsetY, &offsetY)
        if let v = try? c.decodeIfPresent(Double.self, forKey: .manualTracking) { manualTracking = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .manualSmoothness) { manualSmoothness = v }
    }
}
