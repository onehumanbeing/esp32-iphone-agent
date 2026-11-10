import CoreGraphics
import Foundation
import ImageIO

/// Small image checks on screen frames: did the screen change, and where is the pointer. Port of vision.py.
enum Vision {
    /// Top share of the frame never compared: the status bar, where the Dynamic Island shows our Live Activity.
    static let topMask = 0.06

    /// Run pixel work off the main thread. Full-frame checks there held it 2-4 s per tap in a Debug build, so the
    /// Wi-Fi video's keepalive went out late and the board fell back to BLE (2026-11-06).
    static func off<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Lets exactly one caller through: a Vision request can run its completion handler and still make `perform`
    /// throw, and a continuation resumed twice traps (SIGTRAP typing Chinese, issue #111).
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

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
    /// `quiet`: spots (fractions) that changed on their own before the gesture (`motion`); the fine pass skips them.
    static func changed(_ before: Data?, _ after: Data?, ignore: [CGPoint] = [], quiet: [CGRect] = [],
                        threshold: Double = 1.0) -> Bool {
        guard let before, let after, let a = image(before), let b = image(after) else { return true }
        if a.width != b.width || a.height != b.height { return true }
        let counts = kept(ignore)
        if coarse(a, b, counts, threshold) { return true }  // a big change: new screen, scrolled list
        let w = a.width / 2, h = a.height / 2  // fine pass for small changes, at half resolution
        let hit = hits(gray(a, w, h), gray(b, w, h), counts, quiet: quiet)
        return beyondPointer(patches(hit, w, h), w)
    }

    /// A connected patch of changed pixels: its size and bounding box, in pixels.
    struct Patch {
        var n: Int, x0: Int, y0: Int, x1: Int, y1: Int
        var w: Int { x1 - x0 + 1 }
        var h: Int { y1 - y0 + 1 }
        /// The pointer showing, fading or moving off its mask: a solid round spot 3-8% of the screen width (a
        /// checkmark or a glyph is a thin stroke and fills far less of its box).
        func isPointer(_ width: Int) -> Bool {
            let lo = 0.03 * Double(width), hi = 0.08 * Double(width), ratio = Double(w) / Double(h)
            return lo...hi ~= Double(w) && lo...hi ~= Double(h) && 0.7...1.43 ~= ratio && Double(n) >= 0.6 * Double(w * h)
        }
    }

    private static func hits(_ fa: Gray, _ fb: Gray, _ counts: (Int, Int, Int) -> Bool, quiet: [CGRect]) -> [Bool] {
        let (w, h) = (fa.w, fa.h)
        let still = quiet.map { CGRect(x: $0.minX * Double(w), y: $0.minY * Double(h), width: $0.width * Double(w),
                                       height: $0.height * Double(h)) }
        var hit = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where abs(Int(fa.px[i]) - Int(fb.px[i])) > 25 && counts(i, w, h) {
            let p = CGPoint(x: i % w, y: i / w)
            hit[i] = !still.contains { $0.contains(p) }
        }
        return hit
    }

    /// 8-connected patches of `hit`, specks under 3 pixels left out (video noise).
    static func patches(_ hit: [Bool], _ w: Int, _ h: Int) -> [Patch] {
        var seen = [Bool](repeating: false, count: w * h), out: [Patch] = []
        for start in 0..<(w * h) where hit[start] && !seen[start] {
            var stack = [start], p = Patch(n: 0, x0: start % w, y0: start / w, x1: start % w, y1: start / w)
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                p.n += 1
                (p.x0, p.x1, p.y0, p.y1) = (min(p.x0, x), max(p.x1, x), min(p.y0, y), max(p.y1, y))
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where hit[ny * w + nx] && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true
                        stack.append(ny * w + nx)
                    }
                }
            }
            if p.n >= 3 { out.append(p) }
        }
        return out
    }

    /// Whether small changes are a result and not just the pointer: shown or faded where its masks don't expect it,
    /// it read as "changed" and hid a tap that did nothing. Up to two pointer spots (where it was, where it is)
    /// are not a change.
    static func beyondPointer(_ patches: [Patch], _ width: Int) -> Bool {
        guard patches.reduce(0, { $0 + $1.n }) >= 6 else { return false }
        let pointers = patches.filter { $0.isPointer(width) }.count
        return pointers < patches.count || pointers > 2
    }

    /// Where the screen changed on its own between two frames, e.g. while the model looked: a spinner, a caret,
    /// the pointer fading (fractions, padded). Nothing when the change is big or covers a fifth of the screen:
    /// then it was still changing and no spot is quiet.
    static func motion(_ before: Data?, _ after: Data?) -> [CGRect] {
        guard let before, let after, let a = image(before), let b = image(after), a.width == b.width,
              a.height == b.height else { return [] }
        let counts = kept([])
        if coarse(a, b, counts, 1.0) { return [] }
        let w = a.width / 2, h = a.height / 2, pad = 0.02 * Double(w)
        let rects = patches(hits(gray(a, w, h), gray(b, w, h), counts, quiet: []), w, h).map {
            CGRect(x: (Double($0.x0) - pad) / Double(w), y: (Double($0.y0) - pad) / Double(h),
                   width: (Double($0.w) + 2 * pad) / Double(w), height: (Double($0.h) + 2 * pad) / Double(h))
        }
        return rects.reduce(0) { $0 + $1.width * $1.height } > 0.2 ? [] : rects
    }

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
    /// `quiet`: spots (fractions) that moved by themselves just before (`motion`); never the pointer.
    static func pointer(_ before: Data, _ after: Data, near: CGPoint, shift: Double,
                        reach: CGPoint = CGPoint(x: 0.12, y: 0.08), quiet: [CGRect] = []) -> CGPoint? {
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
        let still = quiet.map { CGRect(x: $0.minX * Double(w), y: $0.minY * Double(h), width: $0.width * Double(w),
                                       height: $0.height * Double(h)) }
        var hits: [(Int, Int)] = []
        for y in top..<bottom {
            for x in left..<right where abs(Int(a.px[y * w + x]) - Int(b.px[y * w + x])) > 30
                && !still.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) {
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
