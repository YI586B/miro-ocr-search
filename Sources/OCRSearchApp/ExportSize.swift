import Foundation
import CoreGraphics

/// How large exported images are, as a percentage of each image's own size — for showing them on
/// larger displays. Set in Settings ▸ Export and applied to every export (Export as PNG, Images to
/// directory, Miro) whether highlights are on or not; the save panels and the Miro sheet say
/// when it is not 100%.
///
/// The image's own pixels are scaled up smoothly; the redrawn text and boxes are drawn at the final
/// size, so they stay sharp. The watermark does not scale: it is the size it is on the original
/// image, in the corner of the export. See renderExportPNG.
enum ExportSize {
    static let key = "exportSizePercent"
    /// A little larger than the image, for larger displays: a 1206 × 2622 iPhone screenshot comes
    /// out 1356 × 2947.
    static let defaultPercent = 112.4
    static let range = 25.0...400.0
    static let presets: [Double] = [100, 112.4, 124.8, 150.6]

    static func percent(_ d: UserDefaults = .standard) -> Double {
        guard d.object(forKey: key) != nil else { return defaultPercent }
        return min(max(d.double(forKey: key), range.lowerBound), range.upperBound)
    }

    /// The factor renderExportPNG takes.
    static func scale(_ d: UserDefaults = .standard) -> CGFloat { CGFloat(percent(d) / 100) }

    /// The size an image of `width` × `height` pixels is exported at.
    static func outputSize(width: Int, height: Int, scale: CGFloat) -> (width: Int, height: Int) {
        guard scale != 1 else { return (width, height) }
        return (max(1, Int((CGFloat(width) * scale).rounded())), max(1, Int((CGFloat(height) * scale).rounded())))
    }

    /// "112.44%", with no trailing zeros.
    static func label(_ percent: Double) -> String {
        let s = String(format: "%.2f", percent)
        return (s.hasSuffix(".00") ? String(s.dropLast(3)) : s.hasSuffix("0") ? String(s.dropLast()) : s) + "%"
    }
}
