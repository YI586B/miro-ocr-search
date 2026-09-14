import SwiftUI
import AppKit
import ImageIO

/// Pixels per point for an image: 2 for one saved at 144 dpi, 1 for one at 72.
///
/// This folder mixes both — IMG_0849 is 1356x2948 at 72 dpi while the rest are 1206x2622 at 144 —
/// which is exactly why a size expressed in pixels means a different apparent size from one image
/// to the next. Sizes the user sets and reads are in points, the unit that means the same thing
/// everywhere; this is what converts them for drawing.
func imagePointScale(at path: String) -> CGFloat {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat, dpi > 0 else { return 1 }
    return max(1, (dpi / 72).rounded())
}

/// The background immediately around a box: the most common colour in a thin ring just outside
/// it, as (r, g, b) in 0...1. `box` is in bitmap pixels, top-left origin.
///
/// This replaced averaging four points, one past the middle of each edge at 15% of the box's size.
/// In running text those points land on the neighbouring words and on the lines above and below,
/// and on a white page black text averaged in turns the "background" grey. Measured against that
/// grey, white paper is as far off as black ink, so the ink could come out white and the patch
/// grey — dark text redrawn light — and every measurement built on the background went with it.
/// A ring touches neighbours only in places, so the colour it shows most is still the background.
///
/// Colours are grouped at 1/16 steps per channel to find the most common one, then averaged within
/// that group, so a flat background comes back exactly and a slightly noisy one still has a clear
/// winner.
func ringBackground(_ rep: NSBitmapImageRep, box: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    let margin = 2, thickness = max(2, Int((box.height * 0.06).rounded()))
    let inner = box.insetBy(dx: CGFloat(-margin), dy: CGFloat(-margin))
    let outer = inner.insetBy(dx: CGFloat(-thickness), dy: CGFloat(-thickness))
    let x0 = max(Int(outer.minX), 0), x1 = min(Int(outer.maxX), w - 1)
    let y0 = max(Int(outer.minY), 0), y1 = min(Int(outer.maxY), h - 1)
    guard x1 > x0, y1 > y0 else { return nil }
    let perimeter = 2 * ((x1 - x0) + (y1 - y0)) * thickness
    let step = max(1, perimeter / 4000)
    var groups: [Int: (n: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]
    var k = 0
    for y in y0...y1 {
        for x in x0...x1 {
            if CGFloat(x) >= inner.minX, CGFloat(x) < inner.maxX, CGFloat(y) >= inner.minY, CGFloat(y) < inner.maxY { continue }
            k += 1
            guard k % step == 0, let c = rep.colorAt(x: x, y: y) else { continue }
            let key = (Int(c.redComponent * 15.99) << 8) | (Int(c.greenComponent * 15.99) << 4) | Int(c.blueComponent * 15.99)
            let e = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (e.n + 1, e.r + c.redComponent, e.g + c.greenComponent, e.b + c.blueComponent)
        }
    }
    guard let top = groups.values.max(by: { $0.n < $1.n }), top.n > 0 else { return nil }
    let n = CGFloat(top.n)
    return (top.r / n, top.g / n, top.b / n)
}

/// A normalised, bottom-left-origin rect (Vision's) in bitmap pixels, top-left origin.
private func pixelBox(_ rect: CGRect, width w: Int, height h: Int) -> CGRect {
    CGRect(x: rect.minX * CGFloat(w), y: (1 - rect.maxY) * CGFloat(h),
           width: rect.width * CGFloat(w), height: rect.height * CGFloat(h))
}

private func colorComponents(_ c: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let n = NSColor(c)
    return (n.redComponent, n.greenComponent, n.blueComponent)
}

/// Approximate the image's background color immediately around each match box, so text-overlay
/// mode can paint the redrawn word over a same-colored patch instead of just floating on top of
/// the original characters: the most common colour just outside the box (see ringBackground).
/// Falls back to `nil` (caller uses its own default) if the image can't be read as a bitmap.
///
/// Deliberately does NOT call `.usingColorSpace(.sRGB)` on the sampled NSColor: colorAt(x:y:)
/// returns components already tagged NSCalibratedRGBColorSpace that numerically match the raw
/// stored sRGB bytes (verified directly against the PNG's own pixel data), but converting that
/// tag to `.sRGB` applies a real, incorrect gamma remap on top of already-correct numbers —
/// measured shifting (28,28,28)/`#1C1C1C` to (37,37,37)/`#252525`. Using the components as
/// returned, unconverted, matches the source image exactly.
func sampledBackgroundColors(at path: String, rects: [CGRect]) -> [Color?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return Array(repeating: nil, count: rects.count) }
    func sample(_ rect: CGRect) -> Color? {
        guard let bg = ringBackground(rep, box: pixelBox(rect, width: w, height: h)) else { return nil }
        return Color(.sRGB, red: bg.r, green: bg.g, blue: bg.b, opacity: 1)
    }
    return rects.map(sample)
}

/// Where a glyph's edge is taken to be, as a fraction of the peak squared distance from the
/// background. Everything the overlay draws is fitted to the box this produces, so it decides how
/// big the redrawn text comes out.
///
/// It started at 0.25 — the half-way point of the antialiased ramp, since distance is squared, and
/// where a glyph outline nominally sits. Right for a clean outline, wrong for a captured
/// image: text on one carries a softer skirt than the geometry suggests, so 0.25 clipped the outermost
/// lit row off every measurement and every fit came out slightly small.
///
/// Calibrated instead, over 30 cases (ten matches across five images, each in three fonts),
/// by rendering the fit and comparing its ink against the original's:
///
///     edge   mean bias   mean |error|   worst
///     0.25     -1.05%       2.43%        7.7%
///     0.20     -0.79%       2.17%        7.7%
///     0.16     -0.05%       1.43%        5.1%
///     0.12     +0.87%       1.89%        6.9%
///     0.08     +1.42%       2.45%        6.9%
///
/// 0.16 is the turning point on all three measures at once, which is what makes it a calibration
/// rather than a number that suited one image.
let inkEdgeFraction: CGFloat = 0.16

/// One match's original text as measured off the image: the colour of its glyphs, and the box
/// those glyphs actually occupy (normalised, bottom-left origin, like Vision's rects). Both come
/// out of the same single pixel scan, since finding the ink is most of the work either way.
struct InkSample: Sendable {
    var rect: CGRect
    var color: Color
    /// How soft this text's edges are: the distance, in pixels, over which a stroke rises from 20%
    /// to 80% of its contrast with the background. About 1.0 for text drawn straight onto the
    /// pixel grid, more for text that has been through a resample — IMG_0849 is a 12% upscale of a
    /// smaller image and measures ~1.55 where a native one measures ~1.39.
    var edgeRise: CGFloat = 0
    /// Whether the glyphs were actually told apart from what is behind them. Not when the ink
    /// fills Vision's box — then `rect` is the box, not the letters (text over a photo, where the
    /// texture around the letters differs from the background as much as they do). Fitting and
    /// placing fall back to Vision's box, and nothing is blurred, rather than trusting it.
    var isolated: Bool = true
}

/// Above this, a measured edge softness is not believed: text that soft has not been seen on a
/// real capture (native screenshots measure ~1.4px, a 12% upscale ~1.55px), and values like it come
/// from measuring across something that is not a clean glyph edge.
let maximumTrustedEdgeRise: CGFloat = 2.5

/// Ink that fills this share of Vision's box's height or more was not isolated from its
/// surroundings. Clean text measures 0.81-0.90 of the box.
let isolatedInkHeightLimit: CGFloat = 0.97

/// Approximate the color of the text itself within each match box, for text-overlay mode to draw
/// the redrawn word in — rather than always using the manually picked Font color. Samples a grid
/// of points inside the box, first finding the box's background reference the same way
/// sampledBackgroundColors does (its edge midpoints, just outside the box), then averaging
/// whichever interior samples differ *most* from that background — those are the ones most
/// likely to have landed on actual glyph ink rather than background showing through between or
/// around the letters. Falls back to `nil` if the image can't be read as a bitmap, or nothing
/// inside the box stands out from its background at all (e.g. blank space).
func sampledInk(at path: String, rects: [CGRect]) -> [InkSample?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let rep = NSBitmapImageRep(cgImage: cg)
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return Array(repeating: nil, count: rects.count) }
    func sample(_ rect: CGRect) -> InkSample? {
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        guard let bg = ringBackground(rep, box: pixelBox(rect, width: w, height: h)) else { return nil }
        let (bgR, bgG, bgB) = bg

        // Walk the box's pixels rather than a 6x6 grid of them. Most of any match box is
        // background — text has gaps, and glyphs are thin — so a grid that coarse landed only a
        // handful of points on ink at all, and those were as likely to be on an antialiased edge
        // as on the solid middle of a stroke. Stepped only if the box is unusually large, since
        // colorAt(x:y:) allocates an NSColor per call.
        let pxX0 = max(Int(x0 * CGFloat(w)), 0), pxX1 = min(Int(x1 * CGFloat(w)), w - 1)
        let pxY0 = max(Int(yTop * CGFloat(h)), 0), pxY1 = min(Int(yBottom * CGFloat(h)), h - 1)
        guard pxX1 > pxX0, pxY1 > pxY0 else { return nil }
        let area = (pxX1 - pxX0) * (pxY1 - pxY0)
        let step = max(1, Int((Double(area) / 40_000).squareRoot().rounded(.up)))

        var candidates: [(r: CGFloat, g: CGFloat, b: CGFloat, distance: CGFloat, x: Int, y: Int)] = []
        candidates.reserveCapacity(area / (step * step) + 1)
        for py in stride(from: pxY0, through: pxY1, by: step) {
            for px in stride(from: pxX0, through: pxX1, by: step) {
                guard let c = rep.colorAt(x: px, y: py) else { continue }
                let dr = c.redComponent - bgR, dg = c.greenComponent - bgG, db = c.blueComponent - bgB
                candidates.append((c.redComponent, c.greenComponent, c.blueComponent,
                                   dr * dr + dg * dg + db * db, px, py))
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.distance > $1.distance }

        // The peak is taken a little way into the sorted run rather than as the single maximum,
        // so one stray pixel — a compression artefact, part of an icon clipped into the box —
        // cannot define the ink colour on its own.
        let peak = candidates[min(candidates.count - 1, candidates.count / 50)].distance
        guard peak > 0.001 else { return nil }   // nothing stood out from the background

        // Average only the pixels at that peak: the solid interior of the strokes. Everything
        // below it is the antialiased ramp from ink to background, which is by definition a
        // blend of the two, so including it drags the answer towards the background — which is
        // exactly what made white text come out as grey (measured: #EFEFEF instead of white),
        // and what put a colour cast on it when the channels did not blend evenly. Distance is
        // squared, so 0.9 here keeps only pixels about 95% of the way to full ink.
        let core = candidates.prefix { $0.distance >= peak * 0.9 }

        // Within that core, take the most common exact colour rather than the average of them.
        // Flat UI text is a plateau of identical pixels with a thin shoulder of near-misses
        // around it, and averaging still lets that shoulder pull the answer off: measured on a
        // heading whose glyphs are 255 across 204 pixels, the mean came back 253. The mode lands
        // on the plateau exactly. It is only trusted when the plateau is a real one — for text
        // over a gradient, or photographic text, there is no single dominant value and the mean
        // of the core is the better answer.
        var tally: [Int: Int] = [:]
        for c in core {
            let key = (Int((c.r * 255).rounded()) << 16)
                    | (Int((c.g * 255).rounded()) << 8)
                    | Int((c.b * 255).rounded())
            tally[key, default: 0] += 1
        }
        var color: Color
        if let (key, count) = tally.max(by: { $0.value < $1.value }), count * 10 >= core.count {
            color = Color(.sRGB, red: Double((key >> 16) & 255) / 255,
                          green: Double((key >> 8) & 255) / 255,
                          blue: Double(key & 255) / 255, opacity: 1)
        } else {
            let n = CGFloat(core.count)
            color = Color(.sRGB, red: core.reduce(0) { $0 + $1.r } / n,
                          green: core.reduce(0) { $0 + $1.g } / n,
                          blue: core.reduce(0) { $0 + $1.b } / n, opacity: 1)
        }

        // How far each pixel is along the way from the background to the ink colour (0 to 1), and
        // how far off that line it lies. Letters are on the line; over a photo, the texture around
        // them mostly is not — skin and hair differ from the background as much as the ink does,
        // but in another direction — which is what lets them be left out of the ink.
        let ink = colorComponents(color)
        let axis = (r: ink.r - bgR, g: ink.g - bgG, b: ink.b - bgB)
        let axisLength2 = max(axis.r * axis.r + axis.g * axis.g + axis.b * axis.b, 1e-6)
        func along(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> (t: CGFloat, off: CGFloat) {
            let d = (r: c.r - bgR, g: c.g - bgG, b: c.b - bgB)
            let dot = d.r * axis.r + d.g * axis.g + d.b * axis.b
            let dist2 = d.r * d.r + d.g * d.g + d.b * d.b
            return (dot / axisLength2, max(0, dist2 - dot * dot / axisLength2).squareRoot() / axisLength2.squareRoot())
        }

        // The box those glyphs actually occupy. Taken part way up the antialiased ramp — see
        // inkEdgeFraction, which is a fraction of the squared distance, so of the way along it is
        // its square root — rather than at the peak, since the extent has to include the softened
        // outside of a stroke, not just its solid middle.
        //
        // This is the measurement the overlay is sized and placed against, and it is why:
        // Vision's box is NOT a tight wrap around the glyphs, whatever its reputation. Measured
        // on IMG_0849 it runs 8-11% taller than the ink inside it and starts several pixels to
        // the left, so deriving a font size from the box's height came out that much too big and
        // deriving a left edge from the box's edge started that much too early.
        let edge = inkEdgeFraction.squareRoot()
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for c in candidates {
            let a = along((c.r, c.g, c.b))
            guard a.t >= edge, a.off <= 0.35 else { continue }
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Back to normalised, bottom-left origin, matching Vision's own rects.
        let inkRect = CGRect(x: CGFloat(minX) / CGFloat(w),
                             y: 1 - CGFloat(maxY + step) / CGFloat(h),
                             width: CGFloat(maxX + step - minX) / CGFloat(w),
                             height: CGFloat(maxY + step - minY) / CGFloat(h))
        let boxHeight = CGFloat(pxY1 - pxY0 + 1)
        let isolated = CGFloat(maxY + step - minY) < boxHeight * isolatedInkHeightLimit
        // Edge softness, from the same rows: for each horizontal run that climbs from background
        // to ink, how far it takes to go from 20% to 80% of the way. Measured here because this is
        // the one place that already knows where the ink is and what it contrasts against.
        var rises: [CGFloat] = []
        for py in stride(from: max(minY, pxY0), through: min(maxY, pxY1), by: step) where isolated {
            var row: [CGFloat] = []
            for px in stride(from: minX, through: maxX, by: step) {
                guard let c = rep.colorAt(x: px, y: py) else { row.append(0); continue }
                row.append(max(0, along((c.redComponent, c.greenComponent, c.blueComponent)).t))
            }
            guard let hi = row.max(), hi > 0.05 else { continue }
            let t20 = hi * 0.2, t80 = hi * 0.8
            var start: Int? = nil
            for i in row.indices {
                if row[i] >= t20 && row[i] < t80 { if start == nil { start = i } }
                else {
                    if let st = start, row[i] >= t80, i - st <= 8 { rises.append(CGFloat((i - st) * step)) }
                    start = nil
                }
            }
        }
        let measured = rises.isEmpty ? 0 : rises.reduce(0, +) / CGFloat(rises.count)
        // Only a softness measured on isolated letters, and a believable one, is matched.
        let rise = isolated && measured <= maximumTrustedEdgeRise ? measured : 0
        return InkSample(rect: isolated ? inkRect : rect, color: color, edgeRise: rise, isolated: isolated)
    }
    return rects.map(sample)
}

// MARK: - removing the original letters

/// The original letters of one match, painted out: an image the size of `rect` that is transparent
/// except where the letters were, and there holds what is estimated to be behind them. Drawn over
/// the image, it removes the old word without touching anything around it.
struct CleanedPatch: @unchecked Sendable {   // CGImage is immutable once made
    let image: CGImage
    /// Where it goes, in image pixels, bottom-left origin (the export context's own coordinates).
    let rect: CGRect
}

/// For each match whose letters were isolated, its letters painted out (see CleanedPatch).
///
/// This replaces covering the word with a flat rectangle of the background colour, bigger than the
/// word. On a flat app background the two look the same. On a photo the rectangle showed as a solid
/// block over hair or skin; and wherever the rectangle's margin reached a neighbour — the colon in
/// "Background:" — it erased that too, while only the word was drawn back.
///
/// The letters are the pixels at least a little of the way from the background towards the ink
/// colour (see sampledInk) inside the match's box, together with any such pixels joined to them
/// just above or below it — display type often reaches past Vision's box, and the parts outside it
/// used to be left behind as bars — but not ones that merely lie nearby, like the line above. They
/// are widened by a pixel or two so their soft edges go as well, then filled from the pixels around
/// them: each takes the nearest surrounding pixel to its left, right, top and bottom, weighted by
/// closeness, so a flat colour stays exact and a gradient continues smoothly. nil where the letters
/// were not isolated; the flat patch is used there instead.
func cleanedPatches(at path: String, rects: [CGRect], ink: [InkSample?], backgrounds: [Color?]) -> [CleanedPatch?] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return Array(repeating: nil, count: rects.count) }
    let W = image.width, H = image.height
    return rects.indices.map { i -> CleanedPatch? in
        guard let sample = ink[safe: i] ?? nil, sample.isolated, let background = backgrounds[safe: i] ?? nil else { return nil }
        let r = rects[i]
        let box = CGRect(x: r.minX * CGFloat(W), y: (1 - r.maxY) * CGFloat(H),
                         width: r.width * CGFloat(W), height: r.height * CGFloat(H))
        let widen = max(1, Int((box.height * 0.04).rounded()))
        let reach = Int((box.height * 0.3).rounded())   // how far past the box joined letters are followed
        let margin = widen + 3
        let region = box.insetBy(dx: CGFloat(-(2 + margin)), dy: CGFloat(-(reach + margin))).integral
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        let w = Int(region.width), h = Int(region.height)
        guard w > 2, h > 2,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        // The region's pixels, top row first (CGContext rows run bottom-up in drawing, top-down in memory).
        ctx.draw(image, in: CGRect(x: -region.minX, y: -(CGFloat(H) - region.maxY), width: CGFloat(W), height: CGFloat(H)))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let bg = NSColor(background), inkColor = NSColor(sample.color)
        let b = (bg.redComponent * 255, bg.greenComponent * 255, bg.blueComponent * 255)
        let axis = (inkColor.redComponent * 255 - b.0, inkColor.greenComponent * 255 - b.1, inkColor.blueComponent * 255 - b.2)
        let axisLength2 = max(axis.0 * axis.0 + axis.1 * axis.1 + axis.2 * axis.2, 1)

        // How far each pixel is towards the ink, 0 at the background and 1 at the ink.
        func toward(_ x: Int, _ y: Int) -> CGFloat {
            let o = (y * w + x) * 4
            let d = (CGFloat(px[o]) - b.0, CGFloat(px[o + 1]) - b.1, CGFloat(px[o + 2]) - b.2)
            return (d.0 * axis.0 + d.1 * axis.1 + d.2 * axis.2) / axisLength2
        }
        let bx0 = max(0, Int(box.minX - region.minX) - 2), bx1 = min(w - 1, Int(box.maxX - region.minX) + 2)
        let by0 = max(0, Int(box.minY - region.minY) - 2), by1 = min(h - 1, Int(box.maxY - region.minY) + 2)
        let ry0 = max(0, by0 - reach), ry1 = min(h - 1, by1 + reach)
        guard bx1 > bx0, by1 > by0 else { return nil }
        // How much the background itself varies towards the ink, from the band of pixels around the
        // letters' reach: a flat screen barely does, a photo or a printed pattern does a lot, and on
        // those "faintly towards the ink" is the texture, not the letters. Median-based, so the
        // neighbouring words that also fall in the band do not count.
        var band: [CGFloat] = []
        for y in 0..<h {
            for x in 0..<w where x < bx0 - 1 || x > bx1 + 1 || y < ry0 - 1 || y > ry1 + 1 { band.append(toward(x, y)) }
        }
        band.sort()
        let median = band.isEmpty ? 0 : band[band.count / 2]
        let spread = band.isEmpty ? 0 : band.map { abs($0 - median) }.sorted()[band.count / 2] * 1.4826
        let faint = max(0.06, median + 4 * spread)
        // Letters: inside the box, anything even faintly towards the ink (6%, or above the
        // background's own variation); past it, only solid
        // strokes (half way or more) joined to the solid strokes inside. Faint pixels are not
        // followed: over a photo or a pattern the texture itself is faintly towards the ink, and
        // following it spreads across everything nearby.
        var letter = [Bool](repeating: false, count: w * h)
        var solid = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        for y in by0...by1 {
            for x in bx0...bx1 {
                let t = toward(x, y)
                if t >= faint { letter[y * w + x] = true }
                if t >= max(0.5, faint) { solid[y * w + x] = true; queue.append(y * w + x) }
            }
        }
        while let k = queue.popLast() {
            let x = k % w, y = k / w
            for dy in -1...1 {
                for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= bx0, xx <= bx1, yy >= ry0, yy <= ry1, !solid[yy * w + xx],
                          toward(xx, yy) >= max(0.5, faint) else { continue }
                    solid[yy * w + xx] = true; letter[yy * w + xx] = true; queue.append(yy * w + xx)
                }
            }
        }
        // Widened, so the letters' soft edges are taken out with them.
        var mask = letter
        for y in 0..<h {
            for x in 0..<w where letter[y * w + x] {
                for dy in -widen...widen {
                    for dx in -widen...widen {
                        let yy = y + dy, xx = x + dx
                        if yy >= 0, yy < h, xx >= 0, xx < w { mask[yy * w + xx] = true }
                    }
                }
            }
        }
        guard mask.contains(true) else { return nil }

        // Filled from the nearest surrounding pixels in each of the four directions, weighted by
        // closeness: flat colour stays exact, a gradient carries across. Each is the average of the
        // unmasked pixels around it, so a texture is carried across softened rather than drawn out
        // into stripes.
        var rgb = [(CGFloat, CGFloat, CGFloat)](repeating: (0, 0, 0), count: w * h)
        func colour(_ k: Int) -> (CGFloat, CGFloat, CGFloat) {
            let x = k % w, y = k / w
            var sum = (CGFloat(0), CGFloat(0), CGFloat(0)), n: CGFloat = 0
            for yy in max(0, y - 2)...min(h - 1, y + 2) {
                for xx in max(0, x - 2)...min(w - 1, x + 2) where !mask[yy * w + xx] {
                    let o = (yy * w + xx) * 4
                    sum = (sum.0 + CGFloat(px[o]), sum.1 + CGFloat(px[o + 1]), sum.2 + CGFloat(px[o + 2])); n += 1
                }
            }
            return n > 0 ? (sum.0 / n, sum.1 / n, sum.2 / n) : (CGFloat(px[k * 4]), CGFloat(px[k * 4 + 1]), CGFloat(px[k * 4 + 2]))
        }
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] {
                var sum = (CGFloat(0), CGFloat(0), CGFloat(0)), total: CGFloat = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    var xx = x + dx, yy = y + dy, d: CGFloat = 1
                    while xx >= 0, xx < w, yy >= 0, yy < h, mask[yy * w + xx] { xx += dx; yy += dy; d += 1 }
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let c = colour(yy * w + xx), weight = 1 / d
                    sum = (sum.0 + c.0 * weight, sum.1 + c.1 * weight, sum.2 + c.2 * weight); total += weight
                }
                rgb[y * w + x] = total > 0 ? (sum.0 / total, sum.1 / total, sum.2 / total) : (b.0, b.1, b.2)
            }
        }

        // Transparent except where letters were.
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for k in 0..<(w * h) where mask[k] {
            let c = rgb[k]
            out[k * 4] = UInt8(max(0, min(255, c.0.rounded())))
            out[k * 4 + 1] = UInt8(max(0, min(255, c.1.rounded())))
            out[k * 4 + 2] = UInt8(max(0, min(255, c.2.rounded())))
            out[k * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let patch = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CleanedPatch(image: patch, rect: CGRect(x: region.minX, y: CGFloat(H) - region.maxY, width: region.width, height: region.height))
    }
}
