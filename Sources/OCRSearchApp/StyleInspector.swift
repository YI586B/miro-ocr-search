import SwiftUI
import AppKit
import OCRSearchCore

/// The preview window's style panel: text colours and font when Text is on, box look when Boxes
/// is on, then one Reset menu and the note that all of it applies to this image only.
struct StyleInspector: View {
    /// The image's own style; edits are saved per image by PreviewView.
    @Binding var style: OverlayStyle
    @ObservedObject var preview: PreviewModel
    let path: String
    let overlayOn: Bool, showBoxes: Bool, showText: Bool
    /// Re-reads the image and fits everything again; see PreviewView.refresh.
    let recalculate: () -> Void

    var body: some View {
        let box = Color(hex: style.boxHex) ?? .yellow
        let txt = Color(hex: style.textHex) ?? .black
        let bg = Color(hex: style.bgHex) ?? .white
        let boxBinding = Binding<Color>(get: { box }, set: { style.boxHex = $0.hexString })
        let txtBinding = Binding<Color>(get: { txt }, set: { style.textHex = $0.hexString })
        let bgBinding = Binding<Color>(get: { bg }, set: { style.bgHex = $0.hexString })
        return VStack(alignment: .leading, spacing: 14) {
            if showText {
                // Each "match from image" switch comes before the colour it overrides. While it
                // is on, the colour is only used where sampling fails, and says so.
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Color")
                    Toggle("Match text color from image", isOn: $style.autoTextColor)
                        .help("Pick up the text's own ink color from the image and use it for the redrawn word")
                    ColorPicker(style.autoTextColor ? "Fallback text color" : "Text color",
                                selection: txtBinding, supportsOpacity: false)
                    Toggle("Match background from image", isOn: $style.autoBg)
                        .help("Pick up the color immediately around each match and use it as its background")
                    ColorPicker(style.autoBg ? "Fallback background" : "Background",
                                selection: bgBinding, supportsOpacity: false)
                }
                Divider()
                fontSection
                Divider()
            }
            if showBoxes {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader("Box")
                    ColorPicker("Color", selection: boxBinding, supportsOpacity: false)
                    HStack {
                        Text("Fill opacity")
                        Slider(value: $style.opacity, in: 0...0.8)
                        Text("\(Int(style.opacity * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    Toggle("Outline", isOn: $style.outline)
                }
                Divider()
            }
            if !overlayOn || (!showText && !showBoxes) {
                Text(overlayOn ? "Boxes and Text are both off. Turn one on from the Overlay menu to style it."
                               : "The overlay is off. Turn it on from the Overlay button to style it.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            imageScopeFooter
        }
    }

    /// Says that these controls affect this image only, and holds the ways out of that: the one
    /// Reset menu (font only, this image, or a full recalculation) and making this look the default.
    private var imageScopeFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These settings apply to \((path as NSString).lastPathComponent) only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Menu("Reset") {
                    Button("Font to Automatic") { style.resetFontToAutomatic() }
                        .disabled(!style.fontIsOverridden)
                    Button("This Image to Defaults") {
                        OverlayStyle.clear(path)
                        style = OverlayStyle.current()
                    }
                    Divider()
                    Button("Recalculate Everything (⌘R)", action: recalculate).disabled(preview.scanning)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Font to Automatic: auto font, size, spacing and smoothness, regular, no italic. This Image to Defaults: the look from Settings. Recalculate: re-read the image and match everything again.")
                Spacer()
                Button("Save as Default") { style.saveAsDefaults() }
                    .help("Use this look as the starting point for images that have no settings of their own")
            }
        }
    }

    /// The Font section of the style panel: which family, how big, how tightly spaced, and the
    /// weight and slant. Kept apart from body because the combined body grew past what
    /// the type-checker would infer in reasonable time, and because this is the part of the
    /// panel with real logic in it.
    @ViewBuilder private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Laid out like an ordinary text-editing toolbar (font, point size,
            // then Bold/Italic toggles) rather than a settings-style option list.
            // Picking a font or typing a value overrides whatever auto-match/fit
            // found; "Auto" in the font menu, the Auto buttons, or Reset ▸ Font to
            // Automatic goes back to automatic.
            // The auto-fitted size this field shows while nothing is overriding
            // it. Deliberately the *first* match's size and not the hovered one:
            // the guard below decides whether a commit is a real edit by comparing
            // it against what the field was showing, and a value that moves with
            // the cursor defeats that. Hovering a smaller match redrew the field,
            // and the next commit then looked like the user had asked for the
            // previous, larger number — which is how a 15pt override got stored
            // and made every match on the page 15pt, several too large for the
            // smaller ones. Per-match sizes are still on the hover card.

            let autoSizeShown = Double(((preview.fontSizes.first ?? 17) / preview.imageScale).rounded())
            let sizeBinding = Binding<Double>(
                get: { style.manualSize > 0 ? style.manualSize : autoSizeShown },
                // A TextField(value:) commits whatever it is currently showing
                // every time it loses focus, whether or not the user typed
                // anything -- and while the size is automatic, what it shows is
                // the auto-fitted size. Writing that straight through silently
                // turned "auto" into a manual override pinned to one match on one
                // image, which then never adapted again: the font size looked
                // stuck, and auto-fit looked broken. So a value that matches what
                // auto is already offering is not an override; only a value the
                // user actually changed is. (This was found in the wild as a
                // stored override of exactly 17pt -- the placeholder this field
                // falls back to before anything has been fitted.)
                set: { typed in
                    let v = max(typed, 1)
                    guard style.manualSize > 0 || abs(v - autoSizeShown) >= 0.5 else { return }
                    style.manualSize = v
                }
            )
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Font")
                Toggle("Match font from image", isOn: Binding(
                    get: { style.autoFont },
                    // Turning it back on drops whatever font was picked, so the
                    // font detected from the image takes over again — which is
                    // what the toggle says it does.
                    set: { on in
                        style.autoFont = on
                        if on { style.manualFont = "" }
                    }))
                    .help("Redraw each match in whichever installed font best matches it (or \(systemFontReplacement) if that's the system font). Picking a font below turns this off.")
                Picker("", selection: Binding<String>(
                        get: { style.manualFont },
                        // Picking a specific font is the opposite of matching one
                        // from the image, so the toggle follows it; choosing
                        // "Auto" turns matching back on.
                        set: { picked in
                            style.manualFont = picked
                            style.autoFont = picked.isEmpty
                        }
                    )) {
                        Text(preview.detectedFont.map { "Auto (\($0))" } ?? "Auto").tag("")
                        Divider()
                        ForEach(candidateFontFamilies(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                // Size, then Bold and Italic, on one row as in a text-editing toolbar.
                HStack(spacing: 6) {
                    Text("Size").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: sizeBinding, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: sizeBinding, in: 1...400).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    // Derived from manualSize rather than stored beside it: a second
                    // flag could disagree with the number it describes, which is
                    // exactly what went wrong with the font toggle.
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualSize == 0 },
                        set: { on in style.manualSize = on ? 0 : autoSizeShown }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Size each match to the glyphs measured on the image. Typing a size turns this off.")
                    Spacer()
                    Toggle(isOn: Binding(get: { style.weight == .bold }, set: { style.weight = $0 ? .bold : .regular })) {
                        Text("B").bold()
                    }.toggleStyle(.button).help("Bold").accessibilityLabel("Bold")
                    Toggle(isOn: $style.italic) {
                        Text("I").italic()
                    }.toggleStyle(.button).help("Italic").accessibilityLabel("Italic")
                }
                // Spacing, fitted to the width the original glyphs occupied. It is
                // what makes a substituted font track the original across a word
                // rather than drifting apart from it, so it is re-fitted whenever
                // the font changes.
                let fittedTracking = Double(((preview.trackings.first ?? 0) / preview.imageScale * 10).rounded() / 10)
                let trackingBinding = Binding<Double>(
                    get: { style.manualTracking ?? fittedTracking },
                    set: { typed in
                        guard style.manualTracking != nil || abs(typed - fittedTracking) >= 0.05
                        else { return }
                        style.manualTracking = typed
                    }
                )
                HStack(spacing: 8) {
                    Text("Spacing").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: trackingBinding, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: trackingBinding, in: -20...20, step: 0.1).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualTracking == nil },
                        set: { on in style.manualTracking = on ? nil : fittedTracking }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Space the letters so the redrawn word spans the same width as the original. Typing a value turns this off.")
                    Spacer()
                }
                // Softness, matched to how soft the covered text's edges are. Text drawn
                // fresh is crisper than text that has been through a screenshot's
                // resampling, and on an image that has been scaled the difference shows.
                let fittedSmoothness = Double(((preview.smoothness.first ?? 0) / preview.imageScale * 100).rounded() / 100)
                let smoothBinding = Binding<Double>(
                    get: { style.manualSmoothness ?? fittedSmoothness },
                    set: { typed in
                        guard style.manualSmoothness != nil || abs(typed - fittedSmoothness) >= 0.005
                        else { return }
                        style.manualSmoothness = max(typed, 0)
                    }
                )
                HStack(spacing: 8) {
                    Text("Smoothness").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    TextField("", value: smoothBinding, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 46)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: smoothBinding, in: 0...10, step: 0.05).labelsHidden()
                    Text("pt").font(.caption).foregroundStyle(.secondary)
                    Toggle("Auto", isOn: Binding(
                        get: { style.manualSmoothness == nil },
                        set: { on in style.manualSmoothness = on ? nil : fittedSmoothness }))
                        .toggleStyle(.button).controlSize(.small)
                        .help("Soften the redrawn text to the same degree as the text it covers. Typing a value turns this off.")
                    Spacer()
                }
                Toggle("Kerning", isOn: $style.kerning)
                    .help("Use the font's own pair kerning. Off spaces every pair evenly.")
            }
        }
    }

    /// Small all-caps caption heading each group of controls in the style panel.
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold).kerning(0.5)
            .foregroundStyle(.secondary)
    }
}
