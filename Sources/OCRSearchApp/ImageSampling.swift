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

/// Approximate the image's background color immediately around each match box, so text-overlay
/// mode can paint the redrawn word over a same-colored patch instead of just floating on top of
/// the original characters. Samples just outside the box on all four sides — at the midpoint of
/// each edge, offset outward by a small margin so it lands past any anti-aliased glyph pixel,
/// never inside the box itself — and averages them; falls back to `nil` (caller uses its own
/// default) if the image can't be read as a bitmap.
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
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        let midX = (x0 + x1) / 2, midY = (yTop + yBottom) / 2
        let marginX = max((x1 - x0) * 0.15, 2 / CGFloat(w)), marginY = max((yBottom - yTop) * 0.15, 2 / CGFloat(h))
        let points: [(CGFloat, CGFloat)] = [
            (midX, yTop - marginY), (midX, yBottom + marginY),   // just above, just below
            (x0 - marginX, midY), (x1 + marginX, midY)           // just left, just right
        ]
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for (nx, ny) in points {
            let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
            let py = min(max(Int(ny * CGFloat(h)), 0), h - 1)
            guard let c = rep.colorAt(x: px, y: py) else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
        guard n > 0 else { return nil }
        return Color(.sRGB, red: r / n, green: g / n, blue: b / n, opacity: 1)
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
}

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
    func colorAt(_ nx: CGFloat, _ ny: CGFloat) -> NSColor? {
        let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
        let py = min(max(Int(ny * CGFloat(h)), 0), h - 1)
        return rep.colorAt(x: px, y: py)
    }
    func sample(_ rect: CGRect) -> InkSample? {
        // Vision rects are normalised with origin bottom-left; bitmap pixel rows run top-down.
        let x0 = rect.minX, x1 = rect.maxX
        let yTop = 1 - rect.maxY, yBottom = 1 - rect.minY
        let midX = (x0 + x1) / 2, midY = (yTop + yBottom) / 2
        let marginX = max((x1 - x0) * 0.15, 2 / CGFloat(w)), marginY = max((yBottom - yTop) * 0.15, 2 / CGFloat(h))
        let bg = [colorAt(midX, yTop - marginY), colorAt(midX, yBottom + marginY),
                  colorAt(x0 - marginX, midY), colorAt(x1 + marginX, midY)].compactMap { $0 }
        guard !bg.isEmpty else { return nil }
        let bgR = bg.map(\.redComponent).reduce(0, +) / CGFloat(bg.count)
        let bgG = bg.map(\.greenComponent).reduce(0, +) / CGFloat(bg.count)
        let bgB = bg.map(\.blueComponent).reduce(0, +) / CGFloat(bg.count)

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

        // The box those glyphs actually occupy. Taken at a quarter of the peak distance — about
        // halfway up the antialiased ramp, which is where a glyph's edge visually is — rather
        // than at the peak, since the extent has to include the softened outside of a stroke, not
        // just its solid middle.
        //
        // This is the measurement the overlay is sized and placed against, and it is why:
        // Vision's box is NOT a tight wrap around the glyphs, whatever its reputation. Measured
        // on IMG_0849 it runs 8-11% taller than the ink inside it and starts several pixels to
        // the left, so deriving a font size from the box's height came out that much too big and
        // deriving a left edge from the box's edge started that much too early.
        let edge = peak * inkEdgeFraction
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for c in candidates where c.distance >= edge {
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Back to normalised, bottom-left origin, matching Vision's own rects.
        let inkRect = CGRect(x: CGFloat(minX) / CGFloat(w),
                             y: 1 - CGFloat(maxY + step) / CGFloat(h),
                             width: CGFloat(maxX + step - minX) / CGFloat(w),
                             height: CGFloat(maxY + step - minY) / CGFloat(h))
        // Edge softness, from the same rows: for each horizontal run that climbs from background
        // to ink, how far it takes to go from 20% to 80% of the way. Measured here because this is
        // the one place that already knows where the ink is and what it contrasts against.
        var rises: [CGFloat] = []
        for py in stride(from: max(minY, pxY0), through: min(maxY, pxY1), by: step) {
            var row: [CGFloat] = []
            for px in stride(from: minX, through: maxX, by: step) {
                guard let c = rep.colorAt(x: px, y: py) else { row.append(0); continue }
                let dr = c.redComponent - bgR, dg = c.greenComponent - bgG, db = c.blueComponent - bgB
                row.append((dr * dr + dg * dg + db * db).squareRoot())
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
        let rise = rises.isEmpty ? 0 : rises.reduce(0, +) / CGFloat(rises.count)
        return InkSample(rect: inkRect, color: color, edgeRise: rise)
    }
    return rects.map(sample)
}
