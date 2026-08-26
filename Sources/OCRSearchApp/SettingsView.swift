import SwiftUI
import AppKit

struct MatchView: View {
    let text: String
    let size: CGSize
    let showBoxes: Bool, showText: Bool
    let box: Color, textColor: Color
    let opacity: Double, outline: Bool
    let design: TextDesign, weight: TextWeight
    var background: Color = .white
    var fontSize: CGFloat = 12
    /// Applied as a view modifier on top of the design's font, rather than resolving a true italic font file: SwiftUI synthesizes an oblique
    /// slant when a real italic member isn't available, which is simpler and more reliably
    /// available across arbitrary installed families than hunting for an "-Italic" variant.
    var italic: Bool = false

    var body: some View {
        ZStack {
            if showText {
                let w = weight.font, d = design.font
                // .leading, not the default .center: the substitute font's natural width rarely
                // matches the original's exactly (that's the whole reason fitting exists), so
                // centering left as much slack on the left as the right, drifting the text's
                // start away from where the original text actually began. Anchoring the left
                // edge instead keeps it aligned with the source regardless of any width slack.
                ZStack(alignment: .leading) {
                    Rectangle().fill(background)
                    Text(text).font(.system(size: fontSize, weight: w, design: d))
                    .italic(italic)
                    .foregroundStyle(textColor)
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

struct SettingsView: View {
    @AppStorage(HL.show) private var show = OverlayStyle.defaults.show
    @AppStorage(HL.showBoxes) private var showBoxes = OverlayStyle.defaults.showBoxes
    @AppStorage(HL.showText) private var showText = OverlayStyle.defaults.showText
    @AppStorage(HL.boxHex) private var boxHex = OverlayStyle.defaults.boxHex
    @AppStorage(HL.opacity) private var opacity = OverlayStyle.defaults.opacity
    @AppStorage(HL.outline) private var outline = OverlayStyle.defaults.outline
    @AppStorage(HL.textHex) private var textHex = OverlayStyle.defaults.textHex
    @AppStorage(HL.autoTextColor) private var autoTextColor = OverlayStyle.defaults.autoTextColor
    @AppStorage(HL.bgHex) private var bgHex = OverlayStyle.defaults.bgHex
    @AppStorage(HL.autoBg) private var autoBg = OverlayStyle.defaults.autoBg
    @AppStorage(HL.design) private var design = OverlayStyle.defaults.design
    @AppStorage(HL.weight) private var weight = OverlayStyle.defaults.weight
    @AppStorage(HL.autoFont) private var autoFont = OverlayStyle.defaults.autoFont
    @AppStorage(HL.manualFont) private var manualFont = OverlayStyle.defaults.manualFont
    @AppStorage(HL.manualSize) private var manualSize = OverlayStyle.defaults.manualSize
    @AppStorage(HL.italic) private var italic = OverlayStyle.defaults.italic

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
                    ForEach(TextDesign.allCases, id: \.self) { Text($0.label).tag($0) }
                }.disabled(autoFont)
                Picker("Weight", selection: $weight) {
                    ForEach(TextWeight.allCases, id: \.self) { Text($0.label).tag($0) }
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
                              background: bg.wrappedValue,
                              // The swatch is 26pt tall while a manual size is in image pixels,
                              // which is a much bigger number; clamp so the sample stays legible
                              // rather than overflowing its own box.
                              fontSize: min(manualSize > 0 ? manualSize
                                            : fittedFontSize(for: "Screen Active", weight: weight.font,
                                                             design: design.font,
                                                             fitting: CGSize(width: 150, height: 26)), 24),
                              italic: italic)
                        .offset(x: -50)
                }.frame(height: 50)
            }

            Button("Reset") { OverlayStyle.defaults.saveAsDefaults() }
        }
        .padding(20).frame(width: 460)
    }
}
