import AppKit

// Verifies the watermark badge in a rendered export, exactly rather than heuristically: the
// export is diffed against its own source image, so the pixels that changed in the bottom-right
// corner ARE the badge, whatever the screenshot happens to have underneath it. (Looking for the
// badge by colour alone does not work — these screenshots are a mix of light and dark mode, and
// several have UI content of their own running into that corner.)
//
// Usage: wmtest.swift <renderedDir> <sourceDir>

func rep(_ url: URL) -> NSBitmapImageRep? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return NSBitmapImageRep(data: d)
}
func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }

let renderedDir = URL(fileURLWithPath: CommandLine.arguments[1])
let sourceDir = URL(fileURLWithPath: CommandLine.arguments[2])
let files = (try! FileManager.default.contentsOfDirectory(atPath: renderedDir.path)).sorted()

print(pad("file", 16) + pad("image", 12) + pad("badge", 10) + pad("margins", 14)
      + pad("wordmark", 10) + pad("centred", 16) + "verdict")
var pass = 0, fail = 0

for f in files {
    guard let out = rep(renderedDir.appendingPathComponent(f)),
          let src = rep(sourceDir.appendingPathComponent(f)) else { continue }
    let W = out.pixelsWide, H = out.pixelsHigh
    guard src.pixelsWide == W, src.pixelsHigh == H else { print("\(f): size mismatch"); fail += 1; continue }

    // Bounding box of everything the render changed in the bottom-right corner.
    var minX = W, maxX = -1, minY = H, maxY = -1
    for y in max(0, H - 120)..<H {
        for x in max(0, W - 150)..<W {
            guard let a = out.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  let b = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                  + abs(a.blueComponent - b.blueComponent)
            if d > 0.01 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX >= minX else { print(pad(f, 16) + "no badge drawn"); fail += 1; continue }
    let bw = maxX - minX + 1, bh = maxY - minY + 1
    let right = W - 1 - maxX, bottom = H - 1 - maxY

    // The wordmark, inside the badge: where the render differs from the source by a lot, versus
    // the badge's translucent fill which shifts it only a little.
    //
    // That separation only holds where the source under the badge is flat. On a corner with
    // content or a strong gradient in it, the translucent fill alone shifts some pixels as much
    // as the wordmark does, and the measurement degenerates to the whole badge. So the corner is
    // checked for uniformity first and centring is simply reported as not measurable otherwise —
    // the geometry above is still exact either way, since it comes from a plain diff.
    var lo = 1.0, hi = 0.0
    for y in minY...maxY {
        for x in minX...maxX {
            guard let b = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            lo = min(lo, b.brightnessComponent); hi = max(hi, b.brightnessComponent)
        }
    }
    let flatCorner = hi - lo < 0.05

    var wx0 = maxX, wx1 = minX, wy0 = maxY, wy1 = minY
    for y in minY...maxY {
        for x in minX...maxX {
            guard let a = out.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  let b = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if abs(a.brightnessComponent - b.brightnessComponent) > 0.30 {
                wx0 = min(wx0, x); wx1 = max(wx1, x); wy0 = min(wy0, y); wy1 = max(wy1, y)
            }
        }
    }
    // Valid only if the separation actually separated something: a box that spans the whole
    // badge means the fill alone cleared the threshold (a flat but very dark corner does this —
    // 50% grey over near-black lifts brightness as much as the wordmark does), so the numbers
    // would be measuring the badge, not the mark.
    let insideBadge = wx1 >= wx0 && wx0 > minX && wx1 < maxX && wy0 > minY && wy1 < maxY
    let haveMark = flatCorner && insideBadge
    let (cl, cr, ct, cb) = (wx0 - minX, maxX - wx1, wy0 - minY, maxY - wy1)

    let sizeOK = bw == 63 && bh == 34
    let marginOK = right == 20 && bottom == 20
    let centredOK = !haveMark || (abs(cl - cr) <= 1 && abs(ct - cb) <= 1)
    let ok = sizeOK && marginOK && centredOK
    ok ? (pass += 1) : (fail += 1)
    print(pad(f, 16) + pad("\(W)x\(H)", 12) + pad("\(bw)x\(bh)", 10)
          + pad("r\(right) b\(bottom)", 14)
          + pad(haveMark ? "\(wx1-wx0+1)x\(wy1-wy0+1)" : "n/a", 10)
          + pad(haveMark ? "L\(cl)/R\(cr) T\(ct)/B\(cb)" : "busy corner", 16)
          + (ok ? "PASS" : "FAIL"))
}
print("\nexpected: badge 63x34, margins r20 b20, wordmark centred within 1px")
print("\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
