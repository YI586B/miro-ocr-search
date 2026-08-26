import SwiftUI
import AppKit

extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255, opacity: 1)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

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
    static let autoFont = "highlightAutoFont"    // auto-match an installed font instead of using design
    static let manualFont = "highlightManualFont"  // overrides the auto-detected family; "" = use it as detected
    static let manualSize = "highlightManualSize"  // fixed size for every match, in image pixels; 0 = auto-fit
    static let italic = "highlightItalic"          // draw matched words in italic
    static let defaultBox = "#FFD60A"
    static let defaultText = "#000000"
    static let defaultBg = "#FFFFFF"

    static func fontDesign(_ s: String) -> Font.Design {
        switch s { case "rounded": return .rounded; case "serif": return .serif
        case "monospaced": return .monospaced; default: return .default }
    }
    static func fontWeight(_ s: String) -> Font.Weight {
        switch s { case "medium": return .medium; case "bold": return .bold; default: return .regular }
    }
}

private extension Font.Design {
    var nsDesign: NSFontDescriptor.SystemDesign {
        switch self { case .rounded: return .rounded; case .serif: return .serif
        case .monospaced: return .monospaced; default: return .default }
    }
}

func nsFont(size: CGFloat, weight: Font.Weight, design: Font.Design) -> NSFont {
    let nsWeight: NSFont.Weight = { switch weight { case .medium: return .medium
        case .bold: return .bold; default: return .regular } }()
    let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
    guard let d = base.fontDescriptor.withDesign(design.nsDesign), let f = NSFont(descriptor: d, size: size)
    else { return base }
    return f
}

/// Largest font size at which `text` (in the given weight/design) fits inside `box`, sized by
/// the font's *cap height* rather than its full line-height metric (ascender + descender +
/// leading, what NSString's own size measurement uses). Vision's bounding box tightly wraps the
/// visible glyphs, not a font's abstract line box, and different fonts/designs carry wildly
/// different amounts of built-in leading for the same visible glyph size — measured against full
/// line height, a design with generous leading gets fitted to a noticeably smaller point size to
/// hit the same box height, even though its actual letters are the same size as one with tighter
/// leading. Cap height scales linearly with point size and is close to font-invariant as a
/// fraction of it, so solving directly from it (no search needed for height) keeps the *visible*
/// text size consistent across designs instead of just the measured line box.
func fittedFontSize(for text: String, weight: Font.Weight, design: Font.Design, fitting box: CGSize) -> CGFloat {
    guard !text.isEmpty, box.width > 1, box.height > 1 else { return 4 }
    let probe = nsFont(size: 100, weight: weight, design: design)
    let capRatio = probe.capHeight / 100
    guard capRatio > 0 else { return 4 }
    var size = box.height / capRatio
    let f = nsFont(size: size, weight: weight, design: design)
    let width = (text as NSString).size(withAttributes: [.font: f]).width
    let allowedWidth = box.width * widthTolerance   // see widthTolerance in FontMatch.swift
    if width > allowedWidth, width > 0 { size *= allowedWidth / width }
    return max(size, 4)
}

/// Breathing room around each match, as a fraction of that match's height, split evenly on both
/// sides. A fraction rather than a fixed number of points: the overlay is drawn into the image at
/// the image's own resolution, so anything expressed in on-screen points would mean a different
/// thing at every zoom level and window size — and did, until it was measured.
let matchBoxPaddingFraction: CGFloat = 0.3
/// Box-mode outline, likewise as a fraction of the match's height.
let boxOutlineFraction: CGFloat = 0.12

struct MatchView: View {
    let text: String
    let size: CGSize
    let showBoxes: Bool, showText: Bool
    let box: Color, textColor: Color
    let opacity: Double, outline: Bool
    let design: String, weight: String
    /// Color sampled from the image right around this match, used when `autoBackground` is on
    /// and sampling succeeded. Otherwise (auto-match off, or sampling failed, e.g. no image
    /// loaded yet) falls back to `background`, the user-picked color — which is then exactly
    /// what's drawn, so the color picker showing it stays truthful.
    var sampled: Color? = nil
    var background: Color = .white
    var autoBackground: Bool = true
    /// The family to draw in — matched from the image, or picked by the user — used in place of
    /// `design`. nil means neither applies, so `design` and `weight` are what to use.
    var matchedFont: String? = nil
    /// Precomputed by the caller (see PreviewView.recomputeFontSizes) rather than fitted here on
    /// every render: fitting requires several font-metric lookups, and this view's body re-runs
    /// on every mouse-move while hovering any match (not just this one), which made auto-font in
    /// particular noticeably laggy when computed inline.
    var fontSize: CGFloat = 12
    /// Precomputed exact renderable name (PostScript name) for matchedFont, see
    /// renderableFontName -- resolving it here on every render was the same kind of hot-path cost.
    var renderedFontName: String? = nil
    /// Color sampled from the text's own ink within this match, used when `autoTextColor` is on
    /// and sampling found something. Otherwise falls back to `textColor`, the user-picked color
    /// -- mirrors `sampled`/`autoBackground` above exactly, for the same reason.
    var sampledTextColor: Color? = nil
    var autoTextColor: Bool = true
    /// Applied as a view modifier on top of whichever font was chosen (matched family or
    /// design), rather than resolving a true italic font file: SwiftUI synthesizes an oblique
    /// slant when a real italic member isn't available, which is simpler and more reliably
    /// available across arbitrary installed families than hunting for an "-Italic" variant.
    var italic: Bool = false

    var body: some View {
        ZStack {
            if showText {
                let w = HL.fontWeight(weight), d = HL.fontDesign(design)
                let useMatch = renderedFontName != nil
                let effectiveTextColor = (autoTextColor ? sampledTextColor : nil) ?? textColor
                // .leading, not the default .center: the substitute font's natural width rarely
                // matches the original's exactly (that's the whole reason fitting exists), so
                // centering left as much slack on the left as the right, drifting the text's
                // start away from where the original text actually began. Anchoring the left
                // edge instead keeps it aligned with the source regardless of any width slack.
                ZStack(alignment: .leading) {
                    Rectangle().fill((autoBackground ? sampled : nil) ?? background)
                    Group {
                        if useMatch {
                            Text(text).font(.custom(renderedFontName!, size: fontSize))
                        }
                        else { Text(text).font(.system(size: fontSize, weight: w, design: d)) }
                    }
                    .italic(italic)
                    .foregroundStyle(effectiveTextColor)
                    .lineLimit(1).minimumScaleFactor(0.9)   // safety net only; sizing above already fits
                }
                .frame(width: size.width, height: size.height)
            }
            if showBoxes {
                Rectangle().fill(box.opacity(opacity))
                    .overlay(Rectangle().stroke(box, lineWidth: outline ? 2 : 0))
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

/// Small card that follows the cursor while hovering a match overlay, showing what it is and
/// how it's drawn: the matched text, its font/size/colors (or box size/color), and how many
/// times that same text was found on this image.
struct MatchInfoPopup: View {
    let text: String
    let showBoxes: Bool, showText: Bool
    /// Which match this is, of how many on the image. The card describes this one instance — its
    /// own size, colours and font — so it says which instance rather than counting how many times
    /// the same word turns up.
    let index: Int
    let total: Int
    /// The size of this match's own glyphs, in the image's pixels.
    let boxSize: CGSize
    let fontSize: CGFloat
    let design: String, weight: String
    let boxColor: Color, textColor: Color, bgColor: Color
    let opacity: Double
    var matchedFont: String? = nil
    /// Whether `matchedFont` was picked by the user rather than matched from the image.
    var fontIsManual: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text).font(.headline).lineLimit(2)
            Text(total > 1 ? "Match \(index) of \(total) on this image" : "The only match on this image")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if showText {
                if let mf = matchedFont {
                    row("Font", "\(mf) \(fontIsManual ? "(picked)" : "(matched)"), \(Int(fontSize.rounded()))pt")
                } else {
                    row("Font", "\(fontLabel) \(weightLabel), \(Int(fontSize.rounded()))pt")
                }
                colorRow("Text color", textColor)
                colorRow("Background", bgColor)
            }
            if showBoxes {
                if showText { Divider() }
                row("Box size", "\(Int(boxSize.width.rounded()))×\(Int(boxSize.height.rounded())) px")
                colorRow("Box color", boxColor)
                row("Fill strength", "\(Int(opacity * 100))%")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.2)))
        .shadow(radius: 6, y: 2)
        .frame(width: 200, alignment: .leading)
    }

    private var fontLabel: String { design == "default" ? "System" : design.capitalized }
    private var weightLabel: String { weight.capitalized }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.caption)
    }
    private func colorRow(_ label: String, _ c: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.3)))
            Text(c.hexString)
        }.font(.caption)
    }
}

struct SettingsView: View {
    @AppStorage(HL.show) private var show = true
    @AppStorage(HL.showBoxes) private var showBoxes = true
    @AppStorage(HL.showText) private var showText = true
    @AppStorage(HL.boxHex) private var boxHex = HL.defaultBox
    @AppStorage(HL.opacity) private var opacity = 0.35
    @AppStorage(HL.outline) private var outline = true
    @AppStorage(HL.textHex) private var textHex = HL.defaultText
    @AppStorage(HL.autoTextColor) private var autoTextColor = true
    @AppStorage(HL.bgHex) private var bgHex = HL.defaultBg
    @AppStorage(HL.autoBg) private var autoBg = true
    @AppStorage(HL.design) private var design = "default"
    @AppStorage(HL.weight) private var weight = "regular"
    @AppStorage(HL.autoFont) private var autoFont = false
    @AppStorage(HL.manualFont) private var manualFont = ""
    @AppStorage(HL.manualSize) private var manualSize: Double = 0
    @AppStorage(HL.italic) private var italic = false

    var body: some View {
        let box = Binding<Color>(get: { Color(hex: boxHex) ?? .yellow }, set: { boxHex = $0.hexString })
        let txt = Binding<Color>(get: { Color(hex: textHex) ?? .black }, set: { textHex = $0.hexString })
        let bg = Binding<Color>(get: { Color(hex: bgHex) ?? .white }, set: { bgHex = $0.hexString })
        Form {
            Toggle("Show overlay on image", isOn: $show)
            Toggle("Bounding boxes", isOn: $showBoxes)
            Toggle("Text in font color", isOn: $showText)

            Section("Box") {
                ColorPicker("Box color", selection: box, supportsOpacity: false)
                HStack {
                    Text("Fill strength")
                    Slider(value: $opacity, in: 0...0.8)
                    Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Toggle("Outline", isOn: $outline)
            }.disabled(!showBoxes)

            Section("Text overlay") {
                HStack {
                    ColorPicker("Font color", selection: txt, supportsOpacity: false)
                    ColorPicker("Background", selection: bg, supportsOpacity: false)
                }
                Toggle("Match text's own color automatically", isOn: $autoTextColor)
                Toggle("Match background color automatically", isOn: $autoBg)
                Picker("Font", selection: $design) {
                    Text("System").tag("default"); Text("Rounded").tag("rounded")
                    Text("Serif").tag("serif"); Text("Monospaced").tag("monospaced")
                }.disabled(autoFont)
                Picker("Weight", selection: $weight) {
                    Text("Regular").tag("regular"); Text("Medium").tag("medium"); Text("Bold").tag("bold")
                }
                Toggle("Italic", isOn: $italic)
                Toggle("Auto-match an installed font", isOn: $autoFont)
                Text(autoTextColor
                     ? "Matched words are re-drawn in their own detected ink color, sized and fonted to closely match the original text. The Font color above is only a fallback, used if sampling isn't possible."
                     : "Matched words are re-drawn in the Font color above, everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(autoBg
                     ? "They're drawn over a background patch sampled from the image around them (so they cover the original text). The Background swatch above is only a fallback — turn this off to use it everywhere instead."
                     : "They're drawn over the Background color above, everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(autoFont
                     ? "Instead of the Font above, each match is redrawn in whichever installed font best matches its size and proportions — or in \(systemFontReplacement) if that turns out to be the system font. To pick a specific font (or nudge the size) instead of the auto-match, use the palette button in an open preview window's toolbar, where you can see what was detected."
                     : "Uses the Font and Weight above for every match.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!showText)

            Section("Preview") {
                ZStack {
                    Rectangle().fill(.gray.opacity(0.25))
                    Text("Screen Active 7h 31m").font(.title3).foregroundStyle(.secondary)
                    MatchView(text: "Screen Active", size: CGSize(width: 150, height: 26),
                              showBoxes: showBoxes, showText: showText,
                              box: box.wrappedValue, textColor: txt.wrappedValue, opacity: opacity,
                              outline: outline, design: design, weight: weight,
                              background: bg.wrappedValue, autoBackground: autoBg,
                              // The swatch is 26pt tall while a manual size is in image pixels,
                              // which is a much bigger number; clamp so the sample stays legible
                              // rather than overflowing its own box.
                              fontSize: min(manualSize > 0 ? manualSize
                                            : fittedFontSize(for: "Screen Active", weight: HL.fontWeight(weight),
                                                             design: HL.fontDesign(design),
                                                             fitting: CGSize(width: 150, height: 26)), 24),
                              italic: italic)
                        .offset(x: -50)
                }.frame(height: 50)
            }

            Button("Reset") {
                show = true; showBoxes = true; showText = true; boxHex = HL.defaultBox; opacity = 0.35; outline = true
                textHex = HL.defaultText; autoTextColor = true; bgHex = HL.defaultBg; autoBg = true
                design = "default"; weight = "regular"; autoFont = false
                manualFont = ""; manualSize = 0; italic = false
            }
        }
        .padding(20).frame(width: 460)
    }
}
