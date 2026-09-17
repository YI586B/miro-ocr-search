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
        // Background patch, then the box, then the text on top — the order the overlay is drawn in.
        // .leading, not the default .center: the substitute font's natural width rarely matches
        // the original's exactly (that's the whole reason fitting exists), so centering left as
        // much slack on the left as the right, drifting the text's start away from where the
        // original text actually began. Anchoring the left edge keeps it aligned with the source.
        ZStack(alignment: .leading) {
            if showText { Rectangle().fill(background) }
            if showBoxes {
                Rectangle().fill(box.opacity(opacity))
                    .overlay(Rectangle().stroke(box, lineWidth: outline ? 2 : 0))
            }
            if showText {
                // Text.italic(Bool) is macOS 13; the plain italic() is not.
                let t = Text(text).font(.system(size: fontSize, weight: weight.font, design: design.font))
                (italic ? t.italic() : t)
                    .foregroundStyle(textColor)
                    .lineLimit(1).minimumScaleFactor(0.9)   // safety net only; sizing above already fits
            }
        }
        .frame(width: size.width, height: size.height)
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
    @AppStorage(HL.autoWeight) private var autoWeight = OverlayStyle.defaults.autoWeight
    @State private var savedLooks = 0
    @State private var confirmForget = false
    @AppStorage(HL.manualFont) private var manualFont = OverlayStyle.defaults.manualFont
    @AppStorage(HL.manualSize) private var manualSize = OverlayStyle.defaults.manualSize
    @AppStorage(HL.italic) private var italic = OverlayStyle.defaults.italic

    /// The Font menu's choices: matching from the image, a family picked by hand (only while one
    /// is saved in the defaults, from a preview's Save as Default), or the system font in a design
    /// with matching off.
    private enum FontChoice: Hashable { case auto, picked(String), design(TextDesign) }
    private enum WeightChoice: Hashable { case auto, fixed(TextWeight) }

    var body: some View {
        let box = Binding<Color>(get: { Color(hex: boxHex) ?? .yellow }, set: { boxHex = $0.hexString })
        let txt = Binding<Color>(get: { Color(hex: textHex) ?? .black }, set: { textHex = $0.hexString })
        let bg = Binding<Color>(get: { Color(hex: bgHex) ?? .white }, set: { bgHex = $0.hexString })
        return VStack(alignment: .leading, spacing: 14) {
            // Laid out like the preview window's style panel (StyleInspector): the same sections,
            // switches and rows, here as the look images start from.
            VStack(alignment: .leading, spacing: 4) {
                SwitchHeading(title: "Show Highlights", isOn: $show,
                              help: "Draw the highlights on images (same as the preview's Overlay button)")
                Text("The look below is where every image starts. An image you restyle in its preview keeps its own look.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HighlightSection(title: "Text Highlight", isOn: $showText, enabled: show,
                             help: "Redraw each match in a font, size and colour matched to the image (same as Overlay ▸ Text)") {
                VStack(alignment: .leading, spacing: 8) {
                    fontRow
                    weightRow
                    colorRow("Colour", fromImage: $autoTextColor, color: txt,
                             help: "Use the text's own ink colour from the image; the colour here is used where sampling fails")
                    colorRow("Background", fromImage: $autoBg, color: bg,
                             help: "Paint out the original letters using the image around them. Off: cover each match with the colour here.")
                    Text("Size, spacing and edges are measured on each image, so they are set in the preview's style panel.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HighlightSection(title: "Box Highlight", isOn: $showBoxes, enabled: show,
                             help: "Draw a box around each match (same as Overlay ▸ Boxes)") {
                VStack(alignment: .leading, spacing: 8) {
                    StyleRow(label: "Colour") {
                        ColorPicker("Box colour", selection: box, supportsOpacity: false).labelsHidden()
                        Text(box.wrappedValue.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                    }
                    StyleRow(label: "Fill") {
                        Slider(value: $opacity, in: 0...0.8)
                        Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Toggle("Outline", isOn: $outline)
                }
            }
            Divider()
            sample(box: box.wrappedValue, text: txt.wrappedValue, background: bg.wrappedValue)
            HStack {
                Spacer()
                Button("Reset to Original Defaults") { OverlayStyle.defaults.saveAsDefaults() }
                    .help("Put every setting on this page back to how the app ships")
            }
            Divider()
            ownLooks
        }
        .padding(20).frame(width: 420)
    }

    private var fontRow: some View {
        StyleRow(label: "Font") {
            Picker("Font", selection: Binding<FontChoice>(
                get: { autoFont ? .auto : manualFont.isEmpty ? .design(design) : .picked(manualFont) },
                set: { choice in
                    switch choice {
                    case .auto: autoFont = true; manualFont = ""
                    case .picked(let f): autoFont = false; manualFont = f
                    case .design(let d): autoFont = false; manualFont = ""; design = d
                    }
                })) {
                    Text("Auto").tag(FontChoice.auto)
                    if !manualFont.isEmpty { Text(manualFont).tag(FontChoice.picked(manualFont)) }
                    Divider()
                    ForEach(TextDesign.allCases, id: \.self) { Text($0.label).tag(FontChoice.design($0)) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .help("Auto redraws each match in whichever installed font has letter shapes closest to the text on the image (or \(systemFontReplacement) if that's the system font). Pick a specific family in a preview's style panel, where you can see what was detected.")
        }
    }

    private var weightRow: some View {
        StyleRow(label: "Weight") {
            Picker("Weight", selection: Binding<WeightChoice>(
                get: { autoWeight ? .auto : .fixed(weight) },
                set: { choice in
                    switch choice {
                    case .auto: autoWeight = true
                    case .fixed(let w): autoWeight = false; weight = w
                    }
                })) {
                    Text("Auto").tag(WeightChoice.auto)
                    Text("Regular").tag(WeightChoice.fixed(.regular))
                    if !autoWeight && weight == .medium { Text("Medium").tag(WeightChoice.fixed(.medium)) }
                    Text("Bold").tag(WeightChoice.fixed(.bold))
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Auto draws each match regular or bold, whichever is closer to its letters on the image")
            Toggle(isOn: $italic) { Text("I").italic() }
                .toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
        }
    }

    /// The colour, with the same Auto button as the style panel: on, the colour is taken from the
    /// image and this one is only used where sampling fails. There is no image here to show a
    /// sampled colour from, so the picker is always live.
    private func colorRow(_ label: String, fromImage: Binding<Bool>, color: Binding<Color>, help: String) -> some View {
        StyleRow(label: label) {
            ColorPicker(label, selection: color, supportsOpacity: false).labelsHidden()
                .help(fromImage.wrappedValue ? "Used where sampling fails" : "Used for every match")
            Text(color.wrappedValue.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            Toggle("Auto", isOn: fromImage).toggleStyle(.button).controlSize(.small).help(help)
        }
    }

    /// A sample of the look on a grey strip, as the overlay draws it.
    private func sample(box: Color, text: Color, background: Color) -> some View {
        ZStack {
            Rectangle().fill(.gray.opacity(0.25))
            Text("Screen Active 7h 31m").font(.title3).foregroundStyle(.secondary)
            MatchView(text: "Screen Active", size: CGSize(width: 150, height: 26),
                      showBoxes: show && showBoxes, showText: show && showText,
                      box: box, textColor: text, opacity: opacity,
                      outline: outline, design: design, weight: weight,
                      background: background,
                      // The swatch is 26pt tall while a manual size is in image pixels, which is a
                      // much bigger number; clamp so the sample stays legible rather than
                      // overflowing its own box.
                      fontSize: min(manualSize > 0 ? manualSize
                                    : fittedFontSize(for: "Screen Active", weight: weight.font,
                                                     design: design.font,
                                                     fitting: CGSize(width: 150, height: 26)), 24),
                      italic: italic)
                .offset(x: -50)
        }
        .frame(height: 50).clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    // Images keep a look of their own only once it differs from these defaults; this clears the
    // ones kept so far, including copies older versions saved on merely opening an image, which
    // then stopped following the defaults.
    private var ownLooks: some View {
        HStack {
            Text(savedLooks == 1 ? "1 image has its own look." : "\(savedLooks) images have their own look.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Forget Every Image's Own Look…") { confirmForget = true }
                .disabled(savedLooks == 0)
        }
        .onAppear { savedLooks = OverlayStyle.savedCount() }
        .confirmationDialog("Forget the look of \(savedLooks) image\(savedLooks == 1 ? "" : "s")?",
                            isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { OverlayStyle.clearAll(); savedLooks = 0 }
        } message: {
            Text("They go back to following the defaults above. Picked fonts, sizes and colours on those images are lost.")
        }
    }
}
