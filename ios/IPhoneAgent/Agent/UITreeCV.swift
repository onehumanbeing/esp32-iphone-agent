import Accelerate
import CoreGraphics
import Foundation

struct Raster {
    let w: Int, h: Int
    var px: [UInt8]  // RGB, 3 bytes per pixel

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        self.w = w
        self.h = h
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn, w > 0, h > 0 else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgba.withUnsafeMutableBytes { s in
            rgb.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
                _ = vImageConvert_RGBA8888toRGB888(&src, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
        px = rgb
    }
}

struct Plane {
    let w: Int, h: Int
    var v: [UInt8]
    init(w: Int, h: Int, fill: UInt8 = 0) { self.w = w; self.h = h; v = [UInt8](repeating: fill, count: w * h) }
}

/// Raw pointers handed to concurrent row bands; every band writes only its own rows.
struct Ptr<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    init(_ b: UnsafeMutableBufferPointer<T>) { p = b.baseAddress! }
    init(_ b: UnsafeBufferPointer<T>) { p = UnsafeMutablePointer(mutating: b.baseAddress!) }
}

enum UITreeCV {

    /// Runs body(y0, y1) over row bands of 0..<h concurrently.
    static func bands(_ h: Int, _ body: (Int, Int) -> Void) {
        let n = min(h, 16)
        DispatchQueue.concurrentPerform(iterations: n) { i in body(h * i / n, h * (i + 1) / n) }
    }

    static func edgeMap(_ img: Raster) -> Plane {
        cannyAny(labPlanes(blur3(img), w: img.w, h: img.h), low: 30, high: 90)
    }

    static func reflect(_ i: Int, _ n: Int) -> Int { n == 1 ? 0 : i < 0 ? -i : i >= n ? 2 * n - 2 - i : i }

    /// 3x3 [1 2 1] Gaussian, OpenCV's reflect-101 border and rounding.
    static func blur3(_ img: Raster) -> [UInt8] {
        let w = img.w, h = img.h, rowLen = w * 3
        var rows = [UInt16](repeating: 0, count: w * h * 3)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        let l0 = reflect(-1, w) * 3, rEnd = reflect(w, w) * 3, last = (w - 1) * 3
        img.px.withUnsafeBufferPointer { s in
            rows.withUnsafeMutableBufferPointer { r in
                out.withUnsafeMutableBufferPointer { o in
                    let s = Ptr(s), r = Ptr(r), o = Ptr(o)
                    bands(h) { y0, y1 in
                        for y in y0..<y1 {
                            let a = s.p + y * rowLen, d = r.p + y * rowLen
                            for k in 0..<3 {
                                d[k] = UInt16(a[l0 + k]) &+ 2 &* UInt16(a[k]) &+ UInt16(a[(w == 1 ? 0 : 3) + k])
                                if w > 1 {
                                    d[last + k] = UInt16(a[last - 3 + k]) &+ 2 &* UInt16(a[last + k]) &+ UInt16(a[rEnd + k])
                                }
                            }
                            if w > 2 {
                                for i in 3..<last { d[i] = UInt16(a[i - 3]) &+ 2 &* UInt16(a[i]) &+ UInt16(a[i + 3]) }
                            }
                        }
                    }
                    bands(h) { y0, y1 in
                        for y in y0..<y1 {
                            let up = r.p + reflect(y - 1, h) * rowLen, mid = r.p + y * rowLen
                            let down = r.p + reflect(y + 1, h) * rowLen, d = o.p + y * rowLen
                            for i in 0..<rowLen { d[i] = UInt8(truncatingIfNeeded: (up[i] &+ 2 &* mid[i] &+ down[i] &+ 8) >> 4) }
                        }
                    }
                }
            }
        }
        return out
    }

    private static let gammaShift = 3, labShift = 12, labShift2 = 15
    private static let gammaTab: [Int] = (0..<256).map { i in
        let x = Float(i) * (1 / 255)
        let v = x <= 0.04045 ? x * (1 / 12.92) : Float(pow((Double(x) + 0.055) * (1 / 1.055), 2.4))
        return Int((255 * Float(1 << gammaShift) * v).rounded())
    }
    private static let cbrtTab: [Int] = (0..<(256 * 3 / 2 * (1 << gammaShift))).map { i in
        let x = Float(i) * (1 / (255 * Float(1 << gammaShift)))
        return Int((Float(1 << labShift2) * (x < 0.008856 ? x * 7.787 + 0.13793103448275862 : cbrtf(x))).rounded())
    }
    private static let labCoeffs: [Int] = {
        let m: [Double] = [0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227]
        let white: [Double] = [0.950456, 1, 1.088754]
        return (0..<9).map { Int((m[$0] * Double(1 << labShift) / white[$0 / 3]).rounded()) }
    }()

    /// OpenCV's 8-bit RGB -> Lab (integer path), one plane per channel.
    static func labPlanes(_ rgb: [UInt8], w: Int, h: Int) -> [Plane] {
        let c = labCoeffs, ls = labShift, ls2 = labShift2
        let lScale = (116 * 255 + 50) / 100, lShift = -((16 * 255 * (1 << ls2) + 50) / 100)
        let half = 1 << (ls - 1), half2 = 1 << (ls2 - 1), ab = 128 * (1 << ls2)
        var planes = [UInt8](repeating: 0, count: w * h * 3)
        rgb.withUnsafeBufferPointer { s in
            planes.withUnsafeMutableBufferPointer { o in
                gammaTab.withUnsafeBufferPointer { g in
                    cbrtTab.withUnsafeBufferPointer { t in
                        let s = Ptr(s), o = Ptr(o), g = Ptr(g), t = Ptr(t), n = w * h
                        bands(h) { y0, y1 in
                            for i in (y0 * w)..<(y1 * w) {
                                let r = g.p[Int(s.p[i * 3])], gr = g.p[Int(s.p[i * 3 + 1])], b = g.p[Int(s.p[i * 3 + 2])]
                                let fx = t.p[(r * c[0] + gr * c[1] + b * c[2] + half) >> ls]
                                let fy = t.p[(r * c[3] + gr * c[4] + b * c[5] + half) >> ls]
                                let fz = t.p[(r * c[6] + gr * c[7] + b * c[8] + half) >> ls]
                                o.p[i] = clamp8((lScale * fy + lShift + half2) >> ls2)
                                o.p[n + i] = clamp8((500 * (fx - fy) + ab + half2) >> ls2)
                                o.p[2 * n + i] = clamp8((200 * (fy - fz) + ab + half2) >> ls2)
                            }
                        }
                    }
                }
            }
        }
        return (0..<3).map { k in
            var p = Plane(w: w, h: h)
            p.v = Array(planes[(k * w * h)..<((k + 1) * w * h)])
            return p
        }
    }

    @inline(__always) static func clamp8(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: max(0, min(255, v))) }

    static func canny(_ src: Plane, low: Int, high: Int) -> Plane { cannyAny([src], low: low, high: high) }

    /// OpenCV-style Canny (L1 gradient, replicated border for Sobel) of each plane, OR-ed into one 0/255 map.
    static func cannyAny(_ planes: [Plane], low: Int, high: Int) -> Plane {
        let w = planes[0].w, h = planes[0].h, n = w * h, pw = w + 2, pn = pw * (h + 2), c = planes.count
        var src = [UInt8](), dx = [Int16](repeating: 0, count: c * n), dy = dx
        src.reserveCapacity(c * n)
        for p in planes { src.append(contentsOf: p.v) }
        var mag = [Int32](repeating: 0, count: c * pn), map = [UInt8](repeating: 0, count: c * n)
        let nb = min(h, 16)
        var strong = [[Int32]](repeating: [], count: nb * c)
        var out = Plane(w: w, h: h)
        src.withUnsafeBufferPointer { sb in
            dx.withUnsafeMutableBufferPointer { dxb in
                dy.withUnsafeMutableBufferPointer { dyb in
                    mag.withUnsafeMutableBufferPointer { mb in
                        map.withUnsafeMutableBufferPointer { mapb in
                            strong.withUnsafeMutableBufferPointer { stb in
                                out.v.withUnsafeMutableBufferPointer { ob in
                                    let s = Ptr(sb), gx = Ptr(dxb), gy = Ptr(dyb), m = Ptr(mb), mp = Ptr(mapb), st = Ptr(stb), o = Ptr(ob)
                                    DispatchQueue.concurrentPerform(iterations: nb) { band in  // Sobel
                                        for k in 0..<c {
                                            sobel(s.p + k * n, gx.p + k * n, gy.p + k * n, m.p + k * pn, w, h, h * band / nb, h * (band + 1) / nb)
                                        }
                                    }
                                    DispatchQueue.concurrentPerform(iterations: nb) { band in  // non-maximum suppression
                                        for k in 0..<c {
                                            st.p[band * c + k] = suppress(gx.p + k * n, gy.p + k * n, m.p + k * pn, mp.p + k * n, w,
                                                                        h * band / nb, h * (band + 1) / nb, low, high)
                                        }
                                    }
                                    DispatchQueue.concurrentPerform(iterations: c) { k in  // hysteresis
                                        var stack = (0..<nb).flatMap { st.p[$0 * c + k] }
                                        let map = mp.p + k * n
                                        while let i32 = stack.popLast() {
                                            let i = Int(i32), x = i % w, y = i / w
                                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                                for nx in max(0, x - 1)...min(w - 1, x + 1) where map[ny * w + nx] == 1 {
                                                    map[ny * w + nx] = 2
                                                    stack.append(Int32(ny * w + nx))
                                                }
                                            }
                                        }
                                    }
                                    bands(h) { y0, y1 in
                                        for i in (y0 * w)..<(y1 * w) {
                                            var e = false
                                            for k in 0..<c where mp.p[k * n + i] == 2 { e = true }
                                            if e { o.p[i] = 255 }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    private static func sobel(_ s: UnsafeMutablePointer<UInt8>, _ dx: UnsafeMutablePointer<Int16>, _ dy: UnsafeMutablePointer<Int16>,
                              _ mag: UnsafeMutablePointer<Int32>, _ w: Int, _ h: Int, _ y0: Int, _ y1: Int) {
        for y in y0..<y1 {
            let a = s + max(y - 1, 0) * w, b = s + y * w, d = s + min(y + 1, h - 1) * w
            let mrow = mag + (y + 1) * (w + 2) + 1
            for x in 0..<w {
                let xm = max(x - 1, 0), xp = min(x + 1, w - 1)
                let gx = (Int(a[xp]) + 2 * Int(b[xp]) + Int(d[xp])) - (Int(a[xm]) + 2 * Int(b[xm]) + Int(d[xm]))
                let gy = (Int(d[xm]) + 2 * Int(d[x]) + Int(d[xp])) - (Int(a[xm]) + 2 * Int(a[x]) + Int(a[xp]))
                dx[y * w + x] = Int16(truncatingIfNeeded: gx)
                dy[y * w + x] = Int16(truncatingIfNeeded: gy)
                mrow[x] = Int32(truncatingIfNeeded: abs(gx) + abs(gy))  // zero border, as OpenCV pads mag
            }
        }
    }

    /// Marks rows y0..<y1: 2 strong, 1 weak edge; returns the strong pixels.
    private static func suppress(_ dx: UnsafeMutablePointer<Int16>, _ dy: UnsafeMutablePointer<Int16>, _ mag: UnsafeMutablePointer<Int32>,
                                 _ map: UnsafeMutablePointer<UInt8>, _ w: Int, _ y0: Int, _ y1: Int, _ low: Int, _ high: Int) -> [Int32] {
        let tg22 = 13573  // tan(22.5°) << 15
        var strong: [Int32] = []
        for y in y0..<y1 {
            for x in 0..<w {
                let row = (y + 1) * (w + 2) + x + 1, m = Int(mag[row])
                guard m > low else { continue }
                let xs = Int(dx[y * w + x]), ys = Int(dy[y * w + x])
                let ax = abs(xs), ay = abs(ys) << 15, tg22x = ax * tg22
                let up = row - (w + 2), down = row + (w + 2)
                let keep: Bool
                if ay < tg22x {
                    keep = m > Int(mag[row - 1]) && m >= Int(mag[row + 1])
                } else if ay > tg22x + (ax << 16) {
                    keep = m > Int(mag[up]) && m >= Int(mag[down])
                } else {
                    let s = (xs ^ ys) < 0 ? -1 : 1
                    keep = m > Int(mag[up - s]) && m > Int(mag[down + s])
                }
                guard keep else { continue }
                if m > high {
                    map[y * w + x] = 2
                    strong.append(Int32(y * w + x))
                } else {
                    map[y * w + x] = 1
                }
            }
        }
        return strong
    }

    static func dilate(_ p: Plane, _ k: Int) -> Plane { morph(p, k, max: true) }
    static func erode(_ p: Plane, _ k: Int) -> Plane { morph(p, k, max: false) }
    static func close(_ p: Plane, _ k: Int) -> Plane { erode(dilate(p, k), k) }

    /// Square max / min filter over the pixels inside the image (vImage clips the kernel at the edges).
    private static func morph(_ p: Plane, _ k: Int, max isMax: Bool) -> Plane {
        var out = Plane(w: p.w, h: p.h)
        p.v.withUnsafeBytes { s in
            out.v.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress), height: vImagePixelCount(p.h),
                                        width: vImagePixelCount(p.w), rowBytes: p.w)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(p.h), width: vImagePixelCount(p.w), rowBytes: p.w)
                let n = vImagePixelCount(k), flags = vImage_Flags(kvImageNoFlags)
                _ = isMax ? vImageMax_Planar8(&src, &dst, nil, 0, 0, n, n, flags) : vImageMin_Planar8(&src, &dst, nil, 0, 0, n, n, flags)
            }
        }
        return out
    }

    static func colorSpread(_ img: Raster, _ box: [Int]) -> Double {
        let n = Double((box[2] - box[0]) * (box[3] - box[1]))
        guard n > 0 else { return 0 }
        var spread = 0.0
        img.px.withUnsafeBufferPointer { px in
            for k in 0..<3 {
                var s = 0, s2 = 0  // exact integer sums: the same doubles as summing in Double
                for y in box[1]..<box[3] {
                    for x in box[0]..<box[2] {
                        let v = Int(px[(y * img.w + x) * 3 + k])
                        s += v
                        s2 += v * v
                    }
                }
                let mean = Double(s) / n
                spread += (max(0, Double(s2) / n - mean * mean)).squareRoot()
            }
        }
        return spread / 3
    }
}
