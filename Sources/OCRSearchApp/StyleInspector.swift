import SwiftUI
import AppKit
import OCRSearchCore

/// The preview window's style panel. Top to bottom: which image it applies to and whether that
/// image has a look of its own (with Reset), then Text Highlight and Box Highlight, each with the
/// switch that draws it, then Recalculate and Save as Default.
///
/// A switched-off highlight stays in place, dimmed, rather than disappearing, so the panel does not
/// jump. Those switches are the same settings as Overlay ▸ Text and Overlay ▸ Boxes.
struct StyleInspector: View {
    /// The image's own style; edits are saved per image by PreviewView.
    @Binding var style: OverlayStyle
    @ObservedObject var preview: PreviewModel
    let path: String
    let overlayOn: Bool
    /// Re-reads the image and fits everything again; see PreviewView.refresh.
    let recalculate: () -> Void

    @AppStorage(HL.showBoxes) private var showBoxes = OverlayStyle.defaults.showBoxes
    @AppStorage(HL.showText) private var showText = OverlayStyle.defaults.showText

    private let labelWidth = StyleRow<EmptyView>.labelWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            scopeHeader
            if style.isOffset {
                Text(movedDescription + " The space it left is black, in exports too. Reset ▸ Position puts it back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !overlayOn {
                Text("The overlay is off. Turn it on from the Overlay button to see these.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            section("Text Highlight", isOn: $showText,
                    help: "Redraw each match in a font, size and colour matched to the image (same as Overlay ▸ Text)") {
                textSection
            }
            Divider()
            section("Box Highlight", isOn: $showBoxes,
                    help: "Draw a box around each match (same as Overlay ▸ Boxes)") {
                boxSection
            }
            Divider()
            HStack {
                Button("Recalculate", action: recalculate).disabled(preview.scanning)
                    .help("Re-read the image and match everything again (⌘R)")
                Spacer()
                Button("Save as Default") { style.saveAsDefaults() }
                    .help("Use this look as the starting point for images that have no settings of their own")
            }
        }
    }

    // MARK: header

    /// Which image these settings belong to, and whether it follows the defaults in Settings —
    /// said before anything is changed, since changes here apply to this image only.
    private var scopeHeader: some View {
        let ownLook = style.differs(from: OverlayStyle.current())
        return HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent)
                .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Text(ownLook ? "Own look" : "Defaults")
                .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(ownLook ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15)))
                .foregroundStyle(ownLook ? Color.accentColor : .secondary)
                .fixedSize()
                .help(ownLook
                      ? "This image has its own look, so changes to the defaults in Settings don't reach it. Changes here apply to this image only."
                      : "This image follows the defaults in Settings. Changes here apply to this image only.")
            Spacer(minLength: 4)
            Menu("Reset") {
                Button("Font to Automatic") { style.resetFontToAutomatic() }
                    .disabled(!style.fontIsOverridden)
                Button("Position") { style.offsetX = 0; style.offsetY = 0 }
                    .disabled(!style.isOffset)
                Button("This Image to Defaults") {
                    OverlayStyle.clear(path)
                    style = OverlayStyle.current()
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Font to Automatic: auto font, size, spacing and edges, regular, no italic. Position: put a moved image back. This Image to Defaults: the look from Settings and the image back in place.")
        }
    }

    /// "Moved 40 px left and 12 px down."
    private var movedDescription: String {
        func part(_ v: Double, _ neg: String, _ pos: String) -> String? {
            v == 0 ? nil : "\(Int(abs(v))) px \(v < 0 ? neg : pos)"
        }
        let parts = [part(style.offsetX, "left", "right"), part(style.offsetY, "up", "down")].compactMap { $0 }
        return "Moved " + parts.joined(separator: " and ") + "."
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, isOn: Binding<Bool>, help: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        HighlightSection(title: title, isOn: isOn, enabled: overlayOn, help: help, content: content)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        StyleRow(label: label, content: content)
    }

    @ViewBuilder private var textSection: some View {
        let txt = Binding<Color>(get: { Color(hex: style.textHex) ?? .black }, set: { style.textHex = $0.hexString })
        let bg = Binding<Color>(get: { Color(hex: style.bgHex) ?? .white }, set: { style.bgHex = $0.hexString })
        VStack(alignment: .leading, spacing: 8) {
            fontRow
            fontSourceNote.padding(.leading, labelWidth + 6)
            sizeRow
            weightRow
            // While Auto is on, the swatch is what was picked up from the image (the first
            // match's; the hover card has each match's own) and the chosen colour is kept for
            // where sampling fails.
            colorRow("Colour", fromImage: $style.autoTextColor, custom: txt,
                     sampled: (preview.ink.first ?? nil)?.color,
                     help: "Use the text's own ink colour from the image. Off: use the colour chosen here.")
            colorRow("Background", fromImage: $style.autoBg, custom: bg,
                     sampled: preview.bgColors.first ?? nil,
                     help: "Paint out the original letters using the image around them. Off: cover each match with the colour chosen here.")
            spacingRow
            edgesRow
            Toggle("Kerning", isOn: $style.kerning)
                .help("Use the font's own pair kerning. Off spaces every pair evenly.")
        }
    }

    private var boxSection: some View {
        let box = Binding<Color>(get: { Color(hex: style.boxHex) ?? .red }, set: { style.boxHex = $0.hexString })
        return VStack(alignment: .leading, spacing: 8) {
            row("Colour") {
                ColorPicker("Box colour", selection: box, supportsOpacity: false).labelsHidden()
                Text(box.wrappedValue.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
            }
            row("Fill") {
                Slider(value: $style.opacity, in: 0...0.8)
                Text("\(Int(style.opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            Toggle("Outline", isOn: $style.outline)
        }
    }

    // MARK: text rows

    /// Stands for "matching off, drawn in the plain design" in the font menu, which no family name can be.
    private static let matchingOffTag = "\u{0}off"

    private var fontRow: some View {
        row("Font") {
            // "Auto" is matching the font from the image; picking a family turns matching off and
            // choosing Auto again turns it back on.
            Picker("Font", selection: Binding<String>(
                get: { !style.autoFont && style.manualFont.isEmpty ? Self.matchingOffTag : style.manualFont },
                set: { picked in
                    guard picked != Self.matchingOffTag else { return }
                    style.manualFont = picked
                    style.autoFont = picked.isEmpty
                })) {
                    Text(preview.detectedFont.map { "Auto (\($0))" } ?? "Auto").tag("")
                    if !style.autoFont && style.manualFont.isEmpty {
                        Text("\(style.design.label) (no matching)").tag(Self.matchingOffTag)
                    }
                    Divider()
                    ForEach(candidateFontFamilies(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: .infinity)
                .help("Auto redraws each match in whichever installed font has letter shapes closest to the text on the image (or \(systemFontReplacement) if that's the system font). Picking a font turns this off.")
        }
    }

    /// Where the font being drawn comes from, when it is not detection: a font picked by hand for
    /// this image, or matching switched off. Said outright, with the way back, because otherwise a
    /// picked font looks exactly like a detected one — a font chosen weeks ago on one image kept
    /// being mistaken for what detection found.
    @ViewBuilder private var fontSourceNote: some View {
        let detected = preview.detection.map { "\($0.family)\($0.standsInForSystemFont ? " (for SF)" : "")" }
        if !style.manualFont.isEmpty {
            note("\(style.manualFont) is picked by hand for this image. "
                 + (detected.map { "Detection found \($0)." } ?? "Detection found no close match."),
                 action: "Use detected font") { style.manualFont = ""; style.autoFont = true }
        } else if !style.autoFont {
            note("Font matching is off: matches are drawn in \(style.design.label).",
                 action: "Match font from image") { style.autoFont = true }
        }
    }

    private func note(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform).font(.caption).buttonStyle(.link)
        }
    }

    @ViewBuilder private var sizeRow: some View {
        // The auto-fitted size this field shows while nothing is overriding it. Deliberately the
        // *first* match's size and not the hovered one: the guard below decides whether a commit
        // is a real edit by comparing it against what the field was showing, and a value that
        // moves with the cursor defeats that. Hovering a smaller match redrew the field, and the
        // next commit then looked like the user had asked for the previous, larger number — which
        // is how a 15pt override got stored and made every match on the page 15pt, several too
        // large for the smaller ones. Per-match sizes are still on the hover card.
        let autoSizeShown = Double(((preview.fontSizes.first ?? 17) / preview.imageScale).rounded())
        let sizeBinding = Binding<Double>(
            get: { style.manualSize > 0 ? style.manualSize : autoSizeShown },
            // A TextField(value:) commits whatever it is currently showing every time it loses
            // focus, whether or not the user typed anything -- and while the size is automatic,
            // what it shows is the auto-fitted size. Writing that straight through silently turned
            // "auto" into a manual override pinned to one match on one image, which then never
            // adapted again. So a value that matches what auto is already offering is not an
            // override; only a value the user actually changed is. (This was found in the wild as
            // a stored override of exactly 17pt -- the placeholder this field falls back to before
            // anything has been fitted.)
            set: { typed in
                let v = max(typed, 1)
                guard style.manualSize > 0 || abs(v - autoSizeShown) >= 0.5 else { return }
                style.manualSize = v
            }
        )
        row("Size") {
            numberField(sizeBinding, format: .number)
            Stepper("Size", value: sizeBinding, in: 1...400).labelsHidden()
            Text("pt").font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Derived from manualSize rather than stored beside it: a second flag could disagree
            // with the number it describes, which is exactly what went wrong with the font toggle.
            autoToggle(Binding(get: { style.manualSize == 0 },
                               set: { on in style.manualSize = on ? 0 : autoSizeShown }),
                       help: "Size each match to the glyphs measured on the image. Typing a size turns this off.")
        }
    }

    /// Auto, or a weight chosen by hand. Medium is offered only while it is already the chosen
    /// weight (it can come from Settings); otherwise the choice is regular or bold, as matching makes.
    private enum WeightChoice: Hashable { case auto, fixed(TextWeight) }

    private var weightRow: some View {
        row("Weight") {
            Picker("Weight", selection: Binding<WeightChoice>(
                get: { style.autoWeight ? .auto : .fixed(style.weight) },
                set: { choice in
                    switch choice {
                    case .auto: style.autoWeight = true
                    case .fixed(let w): style.autoWeight = false; style.weight = w
                    }
                })) {
                    Text("Auto").tag(WeightChoice.auto)
                    Text("Regular").tag(WeightChoice.fixed(.regular))
                    if !style.autoWeight && style.weight == .medium {
                        Text("Medium").tag(WeightChoice.fixed(.medium))
                    }
                    Text("Bold").tag(WeightChoice.fixed(.bold))
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Auto draws each match regular or bold, whichever is closer to its letters on the image")
            Toggle(isOn: $style.italic) { Text("I").italic() }
                .toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
        }
    }

    /// Auto (from the image) or a chosen colour, with the same Auto button as Size, Spacing and
    /// Edges. While Auto is on, the swatch shows what was sampled and cannot be edited; switching it
    /// off turns the swatch into a colour picker.
    private func colorRow(_ label: String, fromImage: Binding<Bool>, custom: Binding<Color>,
                          sampled: Color?, help: String) -> some View {
        row(label) {
            if fromImage.wrappedValue {
                let shown = sampled ?? custom.wrappedValue
                RoundedRectangle(cornerRadius: 3).fill(shown)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5), lineWidth: 0.5))
                    .frame(width: 22, height: 16)
                    .help(sampled == nil ? "Nothing sampled yet; \(custom.wrappedValue.hexString) is used where sampling fails"
                                         : "Picked up from the image (first match). \(custom.wrappedValue.hexString) is used where sampling fails.")
                Text(shown.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                ColorPicker(label, selection: custom, supportsOpacity: false).labelsHidden()
                Text(custom.wrappedValue.hexString).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            autoToggle(fromImage, help: help)
        }
    }

    @ViewBuilder private var spacingRow: some View {
        // Spacing, fitted to the width the original glyphs occupied. It is what makes a
        // substituted font track the original across a word rather than drifting apart from it,
        // so it is re-fitted whenever the font changes.
        let fittedTracking = Double(((preview.trackings.first ?? 0) / preview.imageScale * 10).rounded() / 10)
        let trackingBinding = Binding<Double>(
            get: { style.manualTracking ?? fittedTracking },
            set: { typed in
                guard style.manualTracking != nil || abs(typed - fittedTracking) >= 0.05 else { return }
                style.manualTracking = typed
            }
        )
        row("Spacing") {
            numberField(trackingBinding, format: .number)
            Stepper("Spacing", value: trackingBinding, in: -20...20, step: 0.1).labelsHidden()
            Text("pt").font(.caption).foregroundStyle(.secondary)
            Spacer()
            autoToggle(Binding(get: { style.manualTracking == nil },
                               set: { on in style.manualTracking = on ? nil : fittedTracking }),
                       help: "Space the letters so the redrawn word spans the same width as the original. Typing a value turns this off.")
        }
    }

    @ViewBuilder private var edgesRow: some View {
        // Softness, matched to how soft the covered text's edges are. Positive softens (a blur,
        // in points), negative sharpens (-0.3 = 1.3x steeper); what fitEdges found for the first
        // match when nothing is typed.
        let firstBlur = preview.smoothness.first ?? 0, firstSharpen = preview.sharpness.first ?? 1
        let fittedSmoothness = firstBlur > 0
            ? Double((firstBlur / preview.imageScale * 100).rounded() / 100)
            : -Double(((firstSharpen - 1) * 100).rounded() / 100)
        let smoothBinding = Binding<Double>(
            get: { style.manualSmoothness ?? fittedSmoothness },
            set: { typed in
                guard style.manualSmoothness != nil || abs(typed - fittedSmoothness) >= 0.005 else { return }
                style.manualSmoothness = max(typed, -Double(maximumSharpening - 1))
            }
        )
        let sharpest = -Double(maximumSharpening - 1)
        VStack(alignment: .leading, spacing: 4) {
            row("Edges") {
                Text("Crisper").font(.caption).foregroundStyle(.secondary)
                // The slider covers the useful range; the field takes larger blurs.
                Slider(value: Binding(get: { min(smoothBinding.wrappedValue, 2) },
                                      set: { smoothBinding.wrappedValue = ($0 * 100).rounded() / 100 }),
                       in: sharpest...2)
                    .help("Left of the middle sharpens the redrawn text's edges, right of it softens them")
                Text("Softer").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                numberField(smoothBinding, format: .number.precision(.fractionLength(0...2)))
                    .help("Above 0, a blur in points; below 0, sharper edges (-0.3 is 1.3 times steeper)")
                Spacer()
                autoToggle(Binding(get: { style.manualSmoothness == nil },
                                   set: { on in style.manualSmoothness = on ? nil : fittedSmoothness }),
                           help: "Soften or sharpen the redrawn text's edges to match the text it covers. Moving the slider or typing a value turns this off.")
            }
            .padding(.leading, labelWidth + 6)
        }
    }

    // MARK: small controls

    private func numberField<F: ParseableFormatStyle>(_ value: Binding<Double>, format: F) -> some View
    where F.FormatInput == Double, F.FormatOutput == String {
        TextField("", value: value, format: format)
            .textFieldStyle(.roundedBorder).frame(width: 50)
            .multilineTextAlignment(.trailing)
    }

    private func autoToggle(_ isOn: Binding<Bool>, help: String) -> some View {
        Toggle("Auto", isOn: isOn).toggleStyle(.button).controlSize(.small).help(help)
    }
}

// MARK: - shared with Settings

/// A highlight's heading with its on/off switch, and its rows, dimmed while it is off — or while
/// `enabled` is false (the overlay as a whole is off). Used by the style panel and Settings, so the
/// two are laid out the same.
struct HighlightSection<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    let enabled: Bool
    let help: String
    let content: Content

    init(title: String, isOn: Binding<Bool>, enabled: Bool = true, help: String,
         @ViewBuilder content: () -> Content) {
        self.title = title; _isOn = isOn; self.enabled = enabled; self.help = help
        self.content = content()
    }

    var body: some View {
        let active = isOn && enabled
        VStack(alignment: .leading, spacing: 8) {
            SwitchHeading(title: title, isOn: $isOn, enabled: enabled, help: help)
            content
                .disabled(!active)
                .opacity(active ? 1 : 0.45)
        }
    }
}

/// A small all-caps heading, as the style panel and Settings head each group.
struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold).kerning(0.5)
            .foregroundStyle(.secondary)
    }
}

/// A small all-caps heading with its on/off switch at the right.
struct SwitchHeading: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true
    let help: String

    var body: some View {
        HStack {
            SectionHeading(title: title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!enabled).help(help)
        }
    }
}

/// One labelled row; the label column is the same width on every row.
struct StyleRow<Content: View>: View {
    static var labelWidth: CGFloat { 78 }
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label; self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            content
        }
    }
}
