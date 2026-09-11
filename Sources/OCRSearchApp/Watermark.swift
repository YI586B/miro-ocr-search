import SwiftUI
import AppKit
import CryptoKit

/// Sources/assets/icon-1024.png — the composed app icon (see Scripts/make-icon.swift), found
/// through assetURL, so in the app bundle or next to the sources. Used for the Dock icon at
/// runtime and for MiroBadge, so both match the icon the bundle ships.
///
/// Not logo.png, which despite appearances is fully opaque: its "transparent" background is a
/// checkerboard painted into the pixels, so it renders as a literal checkered square anywhere it
/// is drawn.
let appLogo: NSImage? = NSImage(contentsOf: assetURL("icon-1024.png"))

/// The miro badge stamped on the bottom-right of every opened image (see PreviewView) and on
/// every exported one (see drawWatermark) — drawn rather than loaded, from the wordmark in
/// Sources/assets/watermark.svg, resolved the same way as appLogo.
///
/// Vector, not a bitmap: NSImage keeps an SVG as an _NSSVGImageRep and rasterises it at whatever
/// size it is drawn at, so the same artwork is sharp in a scaled-down preview and in a
/// full-resolution export. The bitmap it replaces could only be upscaled.
let watermarkArtwork: NSImage? = NSImage(contentsOf: assetURL("watermark.svg"))

/// The wordmark, recoloured to watermarkInk.
///
/// The artwork carries the near-black it uses on a light page, which is not what is wanted on a
/// grey chip. Recoloured once here rather than at each draw, and rasterised generously so the
/// badge — tens of pixels of wordmark at export size — is always scaling one down rather than stretching
/// one up.
let watermarkWordmark: NSImage? = {
    guard let art = watermarkArtwork, art.size.width > 0 else { return nil }
    let w = 512, h = max(Int((512 / art.size.width * art.size.height).rounded()), 1)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    art.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    // Keeps the letters' coverage, replaces their colour — antialiased edges included.
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(watermarkInk.cgColor)
    ctx.fill(rect)
    guard let img = ctx.makeImage() else { return nil }
    return NSImage(cgImage: img, size: NSSize(width: w, height: h))
}()

/// The badge is 63x34 on an image whose diagonal is this many pixels — a 1206x2622 iPhone
/// image — and scales with the diagonal from there.
let watermarkReferenceDiagonal: CGFloat = 2886.13028
let watermarkReferenceSize = CGSize(width: 63, height: 34)

/// The badge's size in the image's own pixels: it grows with the image's diagonal, so it keeps the
/// same share of any image, portrait or landscape, instead of being one fixed size that looks
/// large on a small image and lost on a big one.
///
///     width  = hypot(image width, image height) × 63 / 2886.13028
///     height = width × 34 / 63
///
/// both rounded to whole pixels, so the badge's edges land on the pixel grid. 63x34 on a
/// 1206x2622 image; 71x38 on 1356x2948; 29x16 on a 1100x735 photo.
func watermarkPixelSize(forImage size: CGSize) -> CGSize {
    let diagonal = hypot(size.width, size.height)
    let width = diagonal * (watermarkReferenceSize.width / watermarkReferenceDiagonal)
    let height = width * (watermarkReferenceSize.height / watermarkReferenceSize.width)
    return CGSize(width: width.rounded(), height: height.rounded())
}

/// Fixed offsets, in the image's own pixels, whatever the badge's size: 20px in from the right
/// edge and 20px up from the bottom.
let watermarkRightMargin: CGFloat = 20

let watermarkBottomMargin: CGFloat = 20

/// The share of the badge's width the wordmark spans, taken from the reference badge, which
/// leaves about 16% padding either side. The wordmark is centred on both axes, unlike the
/// reference, where it sat noticeably high (24% clearance above, 31% below).
let watermarkWordmarkWidthFraction: CGFloat = 0.68

/// 50% grey. The badge lands on images of any colour, so it is translucent rather than a
/// solid chip.
let watermarkBackground = Color(white: 0.5, opacity: 0.5)

/// The wordmark's colour: grey, and darker than the chip it sits on so the letters read against
/// it. One constant, so changing the badge's look is one edit rather than a hunt.
let watermarkInk = NSColor(white: 0.4, alpha: 1)

/// Applied to the badge as a whole, on top of the translucency already in watermarkBackground.
/// The badge carries its own 50% now, so this stays at 1 — it is the single knob for fading the
/// whole thing, wordmark included, without touching the background colour.
let watermarkOpacity: Double = 1

/// Small rounded Miro logo badge, marking the app's Miro-related actions (export button, the
/// export sheet, "open board"). Square, dark card with the wordmark baked in — looks right at
/// any size without needing its own background.
struct MiroBadge: View {
    var size: CGFloat = 16
    var body: some View {
        Group {
            if let appLogo {
                Image(nsImage: appLogo).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Whether the badge is stamped at all, and the gate on turning it off.
///
/// App-wide rather than per image: it is a decision about what leaves this app, not about how one
/// image is being looked at, so it is not part of OverlayStyle and does not travel with a
/// saved per-image look.
///
/// The gate is a speed bump and worth being honest about as one. A password compiled into an app
/// can be recovered from it — storing the hash rather than the text keeps it out of `strings`, but
/// anyone determined can still patch the check out. It stops the badge being switched off by
/// accident or in passing, which is what a gate like this can actually do.
enum Watermark {
    static let key = "watermarkEnabled"
    static let defaultOn = true
    private static let digest = "21a0ff4404a302a0d5435a67e1e62accea0c07b0c48730576f1369808d4597d9"

    static var isOn: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? defaultOn : d.bool(forKey: key)
    }

    static func matches(_ attempt: String) -> Bool {
        SHA256.hash(data: Data(attempt.utf8)).map { String(format: "%02x", $0) }.joined() == digest
    }

    /// Asks for the password. Returns true only if it was right.
    @MainActor static func confirmTurnOff() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Turn off the watermark?"
        alert.informativeText = "The badge will be left off previews and off anything exported. Enter the password to continue."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if matches(field.stringValue) { return true }
        let wrong = NSAlert()
        wrong.messageText = "That password is not right."
        wrong.informativeText = "The watermark has been left on."
        wrong.runModal()
        return false
    }
}
