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

/// "1 result" / "2 results" — every status message below used to print the literal string
/// "result(s)", which reads as a debug placeholder rather than finished copy.
func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

extension Array {
    /// Every per-match array (colours, fonts, sizes) is built alongside `matches` and should be
    /// the same length, but a failed sample legitimately yields a short or empty array; this
    /// keeps the draw loop from trapping on that rather than silently dropping the overlay.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
