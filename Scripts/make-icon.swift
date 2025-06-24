#!/usr/bin/env swift
//
// Builds the app icon assets from Sources/assets/watermark.svg.
//
// Run via ../make-icons.sh, which then calls iconutil to pack the iconset into AppIcon.icns.
//
// The wordmark on its own is not an app icon: it has no background, so on a light Dock or in a
// Finder list there would be nothing to see, and it ignores the icon grid every other macOS icon
// is drawn to. This composes it onto that grid.
//
// The source is the SVG rather than logo.png. logo.png looks like a white wordmark on
// transparency but is in fact fully opaque — the checkerboard is painted into the pixels, not an
// alpha channel — so scaling it into an icon produces a visible checkered square. The SVG is
// clean vector art, and being vector it also stays sharp at 1024.
//
import AppKit

// MARK: - the macOS icon grid
//
// Apple's macOS icon template, expressed for a 1024pt canvas: the artwork does not fill the
// canvas, it sits on a rounded square of 824x824 centred in it, leaving a 100pt margin all round
// for the shadow and for the optical breathing room that makes a Dock of icons line up. The
// corner radius is ~22.4% of the square's side — the "squircle" every system icon uses.
let canvas: CGFloat = 1024
let body: CGFloat = 824
let cornerRadius: CGFloat = 185.4
/// How much of the body's width the wordmark spans. Chosen to leave the wordmark visually
/// centred with generous margins, the way a text-based icon reads best at Dock size.
let wordmarkWidthFraction: CGFloat = 0.60
/// Used for the 16pt and 32pt slots; see renderIcon.
let smallWordmarkWidthFraction: CGFloat = 0.76
/// Background: the same near-black the miro wordmark is drawn in elsewhere in this project
/// (rgb(28,28,30), see watermark.svg), as a slight vertical gradient. Flat black reads as a dead
/// rectangle next to other macOS icons; a few points of lift is what gives it a surface.
let bgTop = NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 48 / 255, alpha: 1)
let bgBottom = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 1)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Sources/assets")

guard let art = NSImage(contentsOf: assets.appendingPathComponent("watermark.svg")) else {
    print("error: could not read Sources/assets/watermark.svg"); exit(1)
}
/// The SVG's own box wraps the wordmark exactly (no padding of its own), so its aspect ratio is
/// the wordmark's and centring the box centres the letters.
let markAspect = art.size.width / art.size.height

/// The wordmark rasterised at `width` points and recoloured white — the artwork's own fill is
/// near-black, which would vanish on this background. Drawn once per icon size rather than
/// scaled from one bitmap, so every slot gets its own clean rasterisation.
func whiteWordmark(width: CGFloat) -> CGImage? {
    let w = max(Int(width.rounded()), 1), h = max(Int((width / markAspect).rounded()), 1)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    art.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    // Keep the glyph coverage, replace the colour: .sourceIn paints white only where the letters
    // already put ink, leaving the antialiased edges intact.
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(rect)
    return ctx.makeImage()
}

/// One square icon at `size` points, drawn at `scale` device pixels per point.
func renderIcon(size: CGFloat, scale: CGFloat) -> Data? {
    let px = Int(size * scale)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let k = CGFloat(px) / canvas     // everything below is authored against the 1024 grid
    ctx.scaleBy(x: k, y: k)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let rect = CGRect(x: (canvas - body) / 2, y: (canvas - body) / 2, width: body, height: body)
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft shadow under the body, as the template has it — subtle, and it is what stops the icon
    // from looking pasted onto the Dock.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(bgBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY), options: [])
    }
    ctx.restoreGState()

    // A wordmark scaled uniformly is unreadable at 16pt — it comes out about 3px tall. The small
    // slots get a proportionally larger mark so it stays a recognisable shape rather than a
    // smudge, which is the same reason Apple ships distinct artwork for the small sizes.
    let fraction = size <= 32 ? smallWordmarkWidthFraction : wordmarkWidthFraction
    let mw = body * fraction
    let mh = mw / markAspect
    if let mark = whiteWordmark(width: mw * k) {
        ctx.draw(mark, in: CGRect(x: rect.midX - mw / 2, y: rect.midY - mh / 2, width: mw, height: mh))
    }

    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

// MARK: - write the set
//
// The ten slots iconutil expects. Every macOS app ships all of them: the small ones are the
// Finder list and menu views, the large ones are Quick Look, Get Info and the App Store.
let sizes: [CGFloat] = [16, 32, 128, 256, 512]
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    for scale in [CGFloat(1), CGFloat(2)] {
        let name = scale == 1 ? "icon_\(Int(size))x\(Int(size)).png" : "icon_\(Int(size))x\(Int(size))@2x.png"
        guard let data = renderIcon(size: size, scale: scale) else { print("error: \(name)"); exit(1) }
        try! data.write(to: iconset.appendingPathComponent(name))
        print("  \(name)  \(Int(size * scale))x\(Int(size * scale))px  \(data.count) bytes")
    }
}

// The 1024 master, kept alongside as the source of truth and as what App Store Connect asks for.
guard let master = renderIcon(size: 1024, scale: 1) else { exit(1) }
try! master.write(to: assets.appendingPathComponent("icon-1024.png"))
print("  icon-1024.png  1024x1024px  \(master.count) bytes")
