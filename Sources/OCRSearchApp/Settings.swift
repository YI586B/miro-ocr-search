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
    static let mode = "highlightMode"            // box | text
    static let boxHex = "highlightHex"           // box colour (also the text-chip background)
    static let opacity = "highlightOpacity"
    static let outline = "highlightOutline"
    static let textHex = "highlightTextHex"
    static let design = "highlightFontDesign"    // default | rounded | serif | monospaced
    static let weight = "highlightFontWeight"    // regular | medium | bold
    static let defaultBox = "#FFD60A"
    static let defaultText = "#000000"

    static func fontDesign(_ s: String) -> Font.Design {
        switch s { case "rounded": return .rounded; case "serif": return .serif
        case "monospaced": return .monospaced; default: return .default }
    }
    static func fontWeight(_ s: String) -> Font.Weight {
        switch s { case "medium": return .medium; case "bold": return .bold; default: return .regular }
    }
}

/// One highlighted match: either a bounding box, or the matched text drawn to fit the box
/// (font color only, no box).
struct MatchView: View {
    let text: String
    let size: CGSize
    let mode: String
    let box: Color, textColor: Color
    let opacity: Double, outline: Bool
    let design: String, weight: String

    var body: some View {
        Group {
            if mode == "text" {
                Text(text)
                    .font(.system(size: max(size.height * 0.8, 4), weight: HL.fontWeight(weight),
                                  design: HL.fontDesign(design)))
                    .foregroundStyle(textColor)
                    .lineLimit(1).minimumScaleFactor(0.3)
                    .frame(width: size.width, height: size.height)
            } else {
                Rectangle().fill(box.opacity(opacity))
                    .overlay(Rectangle().stroke(box, lineWidth: outline ? 2 : 0))
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(HL.show) private var show = true
    @AppStorage(HL.mode) private var mode = "box"
    @AppStorage(HL.boxHex) private var boxHex = HL.defaultBox
    @AppStorage(HL.opacity) private var opacity = 0.35
    @AppStorage(HL.outline) private var outline = true
    @AppStorage(HL.textHex) private var textHex = HL.defaultText
    @AppStorage(HL.design) private var design = "default"
    @AppStorage(HL.weight) private var weight = "regular"

    var body: some View {
        let box = Binding<Color>(get: { Color(hex: boxHex) ?? .yellow }, set: { boxHex = $0.hexString })
        let txt = Binding<Color>(get: { Color(hex: textHex) ?? .black }, set: { textHex = $0.hexString })
        Form {
            Toggle("Show overlay on image", isOn: $show)
            Picker("Show matches as", selection: $mode) {
                Text("Bounding boxes").tag("box")
                Text("Text in font color").tag("text")
            }.pickerStyle(.segmented)

            Section("Box") {
                ColorPicker("Box color", selection: box, supportsOpacity: false)
                HStack {
                    Text("Fill strength")
                    Slider(value: $opacity, in: 0...0.8)
                    Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Toggle("Outline", isOn: $outline)
            }.disabled(mode == "text")

            Section("Text overlay") {
                ColorPicker("Font color", selection: txt, supportsOpacity: false)
                Picker("Font", selection: $design) {
                    Text("System").tag("default"); Text("Rounded").tag("rounded")
                    Text("Serif").tag("serif"); Text("Monospaced").tag("monospaced")
                }
                Picker("Weight", selection: $weight) {
                    Text("Regular").tag("regular"); Text("Medium").tag("medium"); Text("Bold").tag("bold")
                }
                Text("Matched words are re-drawn in this font and color, sized to fit the original text's box. No box is drawn in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(mode == "box")

            Section("Preview") {
                ZStack {
                    Rectangle().fill(.gray.opacity(0.25))
                    Text("Screen Active 7h 31m").font(.title3).foregroundStyle(.secondary)
                    MatchView(text: "Screen Active", size: CGSize(width: 150, height: 26), mode: mode,
                              box: box.wrappedValue, textColor: txt.wrappedValue, opacity: opacity,
                              outline: outline, design: design, weight: weight)
                        .offset(x: -50)
                }.frame(height: 50)
            }

            Button("Reset") {
                show = true; mode = "box"; boxHex = HL.defaultBox; opacity = 0.35; outline = true
                textHex = HL.defaultText; design = "default"; weight = "regular"
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { if mode != "box" && mode != "text" { mode = "box" } }
    }
}
