import CoreGraphics
import Foundation
import ImageIO

/// Small image checks on screen frames: did the screen change, and where is the pointer. Port of vision.py.
enum Vision {
    /// Top share of the frame never compared: the status bar, where the Dynamic Island shows our Live Activity.
    static let topMask = 0.06

    /// A grayscale bitmap (PIL "L" weights), row-major.
    struct Gray {
        let w: Int, h: Int
        let px: [UInt8]
    }

    static func image(_ jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// The image drawn at w x h (bilinear-ish scaling), converted to gray like PIL's convert("L").
    static func gray(_ img: CGImage, _ w: Int, _ h: Int) -> Gray {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var px = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            px[i] = UInt8((r * 299 + g * 587 + b * 114 + 500) / 1000)
        }
        return Gray(w: w, h: h, px: px)
    }

    /// True when the screen content changed, including small things such as a checkmark.
    ///
    /// `ignore` lists screen points (fractions) where the pointer was or went: those spots are masked, so pointer
    /// moves never count. The status bar (clock) is ignored too.
    static func changed(_ before: Data?, _ after: Data?, ignore: [CGPoint] = [], threshold: Double = 1.0) -> Bool {
        guard let before, let after, let a = image(before), let b = image(after) else { return true }
        if a.width != b.width || a.height != b.height { return true }
        // Our own marks never count: the status bar (the run's Live Activity label in the Dynamic Island) and
        // the pointer, in both passes (2026-11-06: a missed tap read as "changed" from those alone).
        let counts = kept(ignore)
        if coarse(a, b, counts, threshold) { return true }  // a big change: new screen, scrolled list
        let w = a.width / 2, h = a.height / 2  // fine pass for small changes, at half resolution
        let fa = gray(a, w, h), fb = gray(b, w, h)
        var hits = 0
        for i in 0..<(w * h) where abs(Int(fa.px[i]) - Int(fb.px[i])) > 25 && counts(i, w, h) { hits += 1 }
        return hits >= 6
    }

    /// True when the area around `at` (fractions; about a word tile) changed, the pointer spots aside.
    static func changed(_ before: Data?, _ after: Data?, at p: CGPoint, ignore: [CGPoint] = []) -> Bool {
        guard let before, let after, let a = image(before), let b = image(after) else { return true }
        if a.width != b.width || a.height != b.height { return true }
        let w = a.width / 2, h = a.height / 2, fa = gray(a, w, h), fb = gray(b, w, h), counts = kept(ignore)
        let x0 = max(0, Int((p.x - 0.06) * Double(w))), x1 = min(w - 1, Int((p.x + 0.06) * Double(w)))
        let y0 = max(0, Int((p.y - 0.02) * Double(h))), y1 = min(h - 1, Int((p.y + 0.02) * Double(h)))
        guard x0 <= x1, y0 <= y1 else { return false }
        var hits = 0
        for y in y0...y1 {
            for x in x0...x1 where abs(Int(fa.px[y * w + x]) - Int(fb.px[y * w + x])) > 25 && counts(y * w + x, w, h) { hits += 1 }
        }
        return hits >= 6
    }

    /// True when the screen changed a lot (new screen, scrolled list): more than a pointer or a checkmark.
    static func bigChange(_ before: Data?, _ after: Data?, ignore: [CGPoint] = []) -> Bool {
        guard let before, let after, let a = image(before), let b = image(after) else { return true }
        if a.width != b.width || a.height != b.height { return true }
        return coarse(a, b, kept(ignore), 1.0)
    }

    /// Pixel i of a w x h bitmap counts: below the status bar and away from every `ignore` point.
    private static func kept(_ ignore: [CGPoint]) -> (Int, Int, Int) -> Bool {
        { i, w, h in
            let x = Double(i % w), y = Double(i / w), r2 = pow(0.05 * Double(w), 2)
            return y > topMask * Double(h)
                && ignore.allSatisfy { pow(x - $0.x * Double(w), 2) + pow(y - $0.y * Double(h), 2) > r2 }
        }
    }

    private static func coarse(_ a: CGImage, _ b: CGImage, _ counts: (Int, Int, Int) -> Bool, _ threshold: Double) -> Bool {
        let sa = gray(a, 32, 64), sb = gray(b, 32, 64)
        let kept = (0..<sa.px.count).filter { counts($0, 32, 64) }
        let total = kept.reduce(0) { $0 + abs(Int(sa.px[$1]) - Int(sb.px[$1])) }
        return Double(total) / Double(max(kept.count, 1)) > threshold
    }

    /// True when two frames show the same screen, loosely: size-independent (a reference from another decode or
    /// an imported intent), the status bar and small things (pointer, badges, the clock) ignored.
    static func similar(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b, let ia = image(a), let ib = image(b) else { return false }
        let w = 36, h = 78, top = Int(topMask * Double(h)) + 1
        let ga = gray(ia, w, h), gb = gray(ib, w, h)
        var total = 0, big = 0
        for i in (top * w)..<(w * h) {
            let d = abs(Int(ga.px[i]) - Int(gb.px[i]))
            total += d
            if d > 40 { big += 1 }
        }
        let n = Double(w * (h - top))
        return Double(total) / n < 10 && Double(big) / n < 0.04
    }

    /// Where the pointer is in `before`, given it moved right by `shift` (fraction of width) in `after`.
    ///
    /// Only the pointer moved between the two frames, so the changed pixels within `reach` of `near` are the
    /// pointer at both spots; their centroid sits shift/2 to the right of the first one. nil if unclear.
    static func pointer(_ before: Data, _ after: Data, near: CGPoint, shift: Double,
                        reach: CGPoint = CGPoint(x: 0.12, y: 0.08)) -> CGPoint? {
        guard let ia = image(before), let ib = image(after), ia.width == ib.width, ia.height == ib.height else {
            return nil
        }
        let w = ia.width, h = ia.height
        let a = gray(ia, w, h), b = gray(ib, w, h)
        let nx = Double(near.x), ny = Double(near.y), rx = Double(reach.x), ry = Double(reach.y)
        let left = max(0, Int((nx - rx) * Double(w)))
        let top = max(Int(0.05 * Double(h)), Int((ny - ry) * Double(h)))  // skip the status bar
        let right = min(w, Int((nx + rx) * Double(w))), bottom = min(h, Int((ny + ry) * Double(h)))
        guard right > left, bottom > top else { return nil }
        var hits: [(Int, Int)] = []
        for y in top..<bottom {
            for x in left..<right where abs(Int(a.px[y * w + x]) - Int(b.px[y * w + x])) > 30 {
                hits.append((x - left, y - top))
            }
        }
        let area = (right - left) * (bottom - top)
        guard hits.count >= 15, hits.count <= area / 4 else { return nil }  // nothing moved, or more than a pointer
        let xs = hits.map(\.0), ys = hits.map(\.1)
        if Double(xs.max()! - xs.min()!) > 0.15 * Double(w) || Double(ys.max()! - ys.min()!) > 0.07 * Double(h) {
            return nil  // not one compact spot
        }
        let cx = Double(xs.reduce(0, +)) / Double(hits.count) + Double(left)
        let cy = Double(ys.reduce(0, +)) / Double(hits.count) + Double(top)
        return CGPoint(x: cx / Double(w) - shift / 2, y: cy / Double(h))
    }
}
