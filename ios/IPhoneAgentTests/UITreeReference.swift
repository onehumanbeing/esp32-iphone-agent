import CoreGraphics
import Foundation
@testable import IPhoneAgent

// Test-only copy of the CV as of 6e65b62 (before the Accelerate rewrite), verbatim but renamed, so the phone can
// check the new code against the old one on its own JPEG decoder (the phone's pixels differ from the Mac's).

enum RefTree {
    static let ocrPad = UITree.ocrPad

    /// UITree.build(_:_:) of 6e65b62: old CV stages, the unchanged layout stages.
    static func build(_ img: Raster, _ lines: UITree.Lines) -> UITree {
        let W = img.w, H = img.h
        let textBoxes = lines.map(\.box)
        let edges = RefCV.edgeMap(img)
        var leaves = lines.map { UINode("text", $0.box, label: $0.text) }
        for (kind, b) in blobs(edges, textBoxes, W, H) where kind == "blob" {
            if Double(textBoxes.reduce(0) { $0 + UITree.inter(b, $1) }) < 0.5 * Double(UITree.area(b)) {
                leaves.append(UINode(classify(img, b, W), b))
            }
        }
        UITree.labelIcons(leaves)
        let rects = filledRects(edges, W, H).map { UINode("container", $0) }
        var top = UITree.prune(UITree.nest(rects, leaves), W, H)
        top = UITree.xyCut(top, [0, 0, W, H])
        UITree.finish(&top, W, H)
        for (i, n) in UITree.walk(top).enumerated() { n.id = i + 1 }
        return UITree(w: W, h: H, nodes: top)
    }

    static func blobs(_ edges: Plane, _ textBoxes: [[Int]], _ W: Int, _ H: Int) -> [(String, [Int])] {
        var e = edges
        for b in textBoxes {
            for y in max(0, b[1] - ocrPad)..<min(H, b[3] + ocrPad) {
                for x in max(0, b[0] - ocrPad)..<min(W, b[2] + ocrPad) { e.v[y * W + x] = 0 }
            }
        }
        let closed = RefCV.close(RefCV.dilate(e, 3), 7)
        return RefCV.components(closed).compactMap { b in
            let w = b[2] - b[0], h = b[3] - b[1]
            if (Double(w) >= 0.9 * Double(W) && h <= 6) || (Double(h) >= 0.5 * Double(H) && w <= 6) { return ("separator", b) }
            if min(w, h) >= 12 && Double(w) <= 0.6 * Double(W) && Double(h) <= 0.35 * Double(H) { return ("blob", b) }
            return nil
        }
    }

    static func filledRects(_ edges: Plane, _ W: Int, _ H: Int) -> [[Int]] {
        let closed = RefCV.close(edges, 3)
        let found = RefCV.contours(closed) { b in
            let w = b[2] - b[0], h = b[3] - b[1]
            return w >= 40 && h >= 24 && Double(w * h) <= 0.6 * Double(W * H)
        }
        let rects = found.filter { $0.area / Double(UITree.area($0.box)) >= 0.8 }.map(\.box)
        var keep: [[Int]] = []  // drop near-duplicates (inner/outer stroke of the same rectangle)
        for b in UITree.stableSorted(rects, by: { -UITree.area($0) }) where !keep.contains(where: {
            Double(UITree.inter(b, $0)) > 0.9 * Double(UITree.area(b)) && Double(UITree.area($0)) < 1.2 * Double(UITree.area(b))
        }) {
            keep.append(b)
        }
        return keep
    }

    static func classify(_ img: Raster, _ box: [Int], _ W: Int) -> String {
        let w = Double(box[2] - box[0]), h = Double(box[3] - box[1])
        if (1.6...2.4).contains(w / h) && h <= 50 { return "control" }  // switch / toggle shape
        if max(w, h) >= 0.22 * Double(W) && RefCV.colorSpread(img, box) > 25 { return "image" }
        return "icon"
    }
}

enum RefCV {
    // MARK: edges

    /// Color-aware edges: max Canny(30, 90) over the Lab channels of the 3x3-blurred image.
    static func edgeMap(_ img: Raster) -> Plane {
        let blurred = blur3(img)
        let lab = labPlanes(blurred, w: img.w, h: img.h)
        var out = Plane(w: img.w, h: img.h)
        // the three channels at once: each Canny is independent (one after another ~12 ms at 540 px, 2026-11-11)
        var edges = [Plane?](repeating: nil, count: lab.count)
        edges.withUnsafeMutableBufferPointer { slots in
            let slots = slots
            DispatchQueue.concurrentPerform(iterations: lab.count) { slots[$0] = canny(lab[$0], low: 30, high: 90) }
        }
        for e in edges.compactMap({ $0 }) {
            for i in 0..<out.v.count where e.v[i] != 0 { out.v[i] = 255 }
        }
        return out
    }

    /// GaussianBlur((3, 3), 0): [1 2 1] / 4 both ways, BORDER_REFLECT_101.
    static func blur3(_ img: Raster) -> [UInt8] {
        let w = img.w, h = img.h
        func reflect(_ i: Int, _ n: Int) -> Int { n == 1 ? 0 : i < 0 ? -i : i >= n ? 2 * n - 2 - i : i }
        var rows = [Int](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let l = (y * w + reflect(x - 1, w)) * 3, c = (y * w + x) * 3, r = (y * w + reflect(x + 1, w)) * 3
                for k in 0..<3 { rows[c + k] = Int(img.px[l + k]) + 2 * Int(img.px[c + k]) + Int(img.px[r + k]) }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            let up = reflect(y - 1, h) * w, mid = y * w, down = reflect(y + 1, h) * w
            for x in 0..<w {
                for k in 0..<3 {
                    let s = rows[(up + x) * 3 + k] + 2 * rows[(mid + x) * 3 + k] + rows[(down + x) * 3 + k]
                    out[(mid + x) * 3 + k] = UInt8((s + 8) >> 4)
                }
            }
        }
        return out
    }

    /// cvtColor(BGR2LAB) for 8-bit images, OpenCV's fixed-point path (RGB2Lab_b: sRGB gamma table, cube-root
    /// table, 12/15-bit shifts), so the planes match cv2 to the bit: L * 255 / 100, a + 128, b + 128 (D65).
    static func labPlanes(_ rgb: [UInt8], w: Int, h: Int) -> [Plane] {
        let gammaShift = 3, labShift = 12, labShift2 = 15
        let gamma: [Int] = (0..<256).map { i in
            let x = Float(i) * (1 / 255)
            let v = x <= 0.04045 ? x * (1 / 12.92) : Float(pow((Double(x) + 0.055) * (1 / 1.055), 2.4))
            return Int((255 * Float(1 << gammaShift) * v).rounded())
        }
        let cbrtTab: [Int] = (0..<(256 * 3 / 2 * (1 << gammaShift))).map { i in
            let x = Float(i) * (1 / (255 * Float(1 << gammaShift)))
            return Int((Float(1 << labShift2) * (x < 0.008856 ? x * 7.787 + 0.13793103448275862 : cbrtf(x))).rounded())
        }
        let m: [Double] = [0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227]
        let white: [Double] = [0.950456, 1, 1.088754]
        let c = (0..<9).map { Int((m[$0] * Double(1 << labShift) / white[$0 / 3]).rounded()) }
        func descale(_ x: Int, _ n: Int) -> Int { (x + (1 << (n - 1))) >> n }
        let lScale = (116 * 255 + 50) / 100, lShift = -((16 * 255 * (1 << labShift2) + 50) / 100)
        let clamp = { (v: Int) in UInt8(max(0, min(255, v))) }
        var planes = [Plane(w: w, h: h), Plane(w: w, h: h), Plane(w: w, h: h)]
        for i in 0..<(w * h) {
            let r = gamma[Int(rgb[i * 3])], g = gamma[Int(rgb[i * 3 + 1])], b = gamma[Int(rgb[i * 3 + 2])]
            let fx = cbrtTab[descale(r * c[0] + g * c[1] + b * c[2], labShift)]
            let fy = cbrtTab[descale(r * c[3] + g * c[4] + b * c[5], labShift)]
            let fz = cbrtTab[descale(r * c[6] + g * c[7] + b * c[8], labShift)]
            planes[0].v[i] = clamp(descale(lScale * fy + lShift, labShift2))
            planes[1].v[i] = clamp(descale(500 * (fx - fy) + 128 * (1 << labShift2), labShift2))
            planes[2].v[i] = clamp(descale(200 * (fy - fz) + 128 * (1 << labShift2), labShift2))
        }
        return planes
    }

    /// cv2.Canny(img, low, high): 3x3 Sobel (BORDER_REPLICATE), L1 magnitude, OpenCV's non-maximum
    /// suppression (TG22 fixed point, > / >= tie rules) and 8-connected hysteresis.
    static func canny(_ src: Plane, low: Int, high: Int) -> Plane {
        let w = src.w, h = src.h
        func at(_ x: Int, _ y: Int) -> Int { Int(src.v[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]) }
        var dx = [Int](repeating: 0, count: w * h), dy = dx, mag = [Int](repeating: 0, count: (w + 2) * (h + 2))
        for y in 0..<h {
            for x in 0..<w {
                let gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
                let gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1))
                dx[y * w + x] = gx
                dy[y * w + x] = gy
                mag[(y + 1) * (w + 2) + x + 1] = abs(gx) + abs(gy)  // zero border, as OpenCV pads mag
            }
        }
        let tg22 = 13573  // tan(22.5°) << 15
        // 0: not an edge, 1: weak, 2: strong
        var map = [UInt8](repeating: 0, count: w * h)
        var stack: [Int] = []
        for y in 0..<h {
            for x in 0..<w {
                let m = mag[(y + 1) * (w + 2) + x + 1]
                guard m > low else { continue }
                let xs = dx[y * w + x], ys = dy[y * w + x]
                let ax = abs(xs), ay = abs(ys) << 15, tg22x = ax * tg22
                let row = (y + 1) * (w + 2) + x + 1, up = row - (w + 2), down = row + (w + 2)
                let keep: Bool
                if ay < tg22x {
                    keep = m > mag[row - 1] && m >= mag[row + 1]
                } else if ay > tg22x + (ax << 16) {
                    keep = m > mag[up] && m >= mag[down]
                } else {
                    let s = (xs ^ ys) < 0 ? -1 : 1
                    keep = m > mag[up - s] && m > mag[down + s]
                }
                guard keep else { continue }
                if m > high {
                    map[y * w + x] = 2
                    stack.append(y * w + x)
                } else {
                    map[y * w + x] = 1
                }
            }
        }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                for nx in max(0, x - 1)...min(w - 1, x + 1) where map[ny * w + nx] == 1 {
                    map[ny * w + nx] = 2
                    stack.append(ny * w + nx)
                }
            }
        }
        var out = Plane(w: w, h: h)
        for i in 0..<map.count where map[i] == 2 { out.v[i] = 255 }
        return out
    }

    // MARK: morphology (square kernels; outside the image never adds (dilate) or removes (erode))

    static func dilate(_ p: Plane, _ k: Int) -> Plane { morph(p, k, max: true) }
    static func erode(_ p: Plane, _ k: Int) -> Plane { morph(p, k, max: false) }
    static func close(_ p: Plane, _ k: Int) -> Plane { erode(dilate(p, k), k) }

    private static func morph(_ p: Plane, _ k: Int, max isMax: Bool) -> Plane {
        let r = k / 2, w = p.w, h = p.h
        var tmp = Plane(w: w, h: h), out = Plane(w: w, h: h)
        let hit: UInt8 = isMax ? 255 : 0
        for y in 0..<h {  // separable: a square kernel is a row pass then a column pass
            for x in 0..<w {
                var v = isMax ? UInt8(0) : UInt8(255)
                for nx in Swift.max(0, x - r)...Swift.min(w - 1, x + r) where p.v[y * w + nx] == hit { v = hit; break }
                tmp.v[y * w + x] = v
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var v = isMax ? UInt8(0) : UInt8(255)
                for ny in Swift.max(0, y - r)...Swift.min(h - 1, y + r) where tmp.v[ny * w + x] == hit { v = hit; break }
                out.v[y * w + x] = v
            }
        }
        return out
    }

    // MARK: regions

    /// connectedComponentsWithStats(connectivity=8) without the background: boxes in label order (raster scan).
    static func components(_ p: Plane) -> [[Int]] {
        let w = p.w, h = p.h
        var seen = [Bool](repeating: false, count: w * h)
        var out: [[Int]] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where p.v[start] != 0 && !seen[start] {
            var box = [start % w, start / w, start % w, start / w]
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where p.v[ny * w + nx] != 0 && !seen[ny * w + nx] {
                        seen[ny * w + nx] = true
                        stack.append(ny * w + nx)
                    }
                }
            }
            out.append([box[0], box[1], box[2] + 1, box[3] + 1])
        }
        return out
    }

    /// findContours(RETR_LIST) reduced to what filled_rects reads: every outer boundary and every hole of every
    /// 8-connected blob, as (bounding box, contour area). Areas come from Pick's theorem on the traced pixels
    /// (polygon through pixel centers), which is what contourArea measures.
    static func contours(_ p: Plane, keep: ([Int]) -> Bool) -> [(box: [Int], area: Double)] {
        let w = p.w, h = p.h
        var label = [Int32](repeating: -1, count: w * h)
        var blobs: [[Int]] = []  // pixel indices per 8-connected blob
        for start in 0..<(w * h) where p.v[start] != 0 && label[start] < 0 {
            let id = Int32(blobs.count)
            var pixels = [start], k = 0
            label[start] = id
            while k < pixels.count {
                let i = pixels[k], x = i % w, y = i / w
                k += 1
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) where p.v[ny * w + nx] != 0 && label[ny * w + nx] < 0 {
                        label[ny * w + nx] = id
                        pixels.append(ny * w + nx)
                    }
                }
            }
            blobs.append(pixels)
        }
        var out: [(box: [Int], area: Double)] = []
        for (id, pixels) in blobs.enumerated() {
            var b = [w, h, -1, -1]
            for i in pixels { b = [min(b[0], i % w), min(b[1], i / w), max(b[2], i % w), max(b[3], i / w)] }
            let outer = [b[0], b[1], b[2] + 1, b[3] + 1]
            // a hole lies inside the blob's box, so a box too small for any kept contour needs no fill
            guard keep(outer) || (outer[2] - outer[0] >= 40 && outer[3] - outer[1] >= 24) else { continue }
            // 4-connected regions of everything that is not this blob, in its box padded by one pixel:
            // the region touching the pad is the outside; the others are its holes.
            let x0 = b[0] - 1, y0 = b[1] - 1, bw = b[2] - b[0] + 3, bh = b[3] - b[1] + 3
            func mine(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < w && y < h && label[y * w + x] == Int32(id)
            }
            var region = [Int32](repeating: -1, count: bw * bh)
            var regions: [(count: Int, box: [Int])] = []
            for s in 0..<(bw * bh) where region[s] < 0 && !mine(x0 + s % bw, y0 + s / bw) {
                let r = Int32(regions.count)
                var queue = [s], q = 0, box = [bw, bh, -1, -1]
                region[s] = r
                while q < queue.count {
                    let i = queue[q], x = i % bw, y = i / bw
                    q += 1
                    box = [min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)]
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where nx >= 0 && ny >= 0 && nx < bw && ny < bh && region[ny * bw + nx] < 0 && !mine(x0 + nx, y0 + ny) {
                        region[ny * bw + nx] = r
                        queue.append(ny * bw + nx)
                    }
                }
                regions.append((queue.count, box))
            }
            // boundary pixels of the blob next to each region (4-neighbors), for Pick's B
            var touching = [Int](repeating: 0, count: regions.count)
            for i in pixels {
                let x = i % w - x0, y = i / w - y0
                var seen: Set<Int32> = []
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    let r = region[ny * bw + nx]
                    if r >= 0, seen.insert(r).inserted { touching[Int(r)] += 1 }
                }
            }
            if keep(outer) {  // outer contour: A = I + B/2 - 1 with I + B = the blob and all it encloses
                let filled = bw * bh - regions[0].count
                out.append((outer, Double(filled) - Double(touching[0]) / 2 - 1))
            }
            for r in 1..<max(1, regions.count) {  // a hole: its pixels inside the traced blob pixels around it
                let hb = regions[r].box
                let box = [x0 + hb[0] - 1, y0 + hb[1] - 1, x0 + hb[2] + 2, y0 + hb[3] + 2]
                if keep(box) { out.append((box, Double(regions[r].count) + Double(touching[r]) / 2 - 1)) }
            }
        }
        return out
    }

    /// Mean over R, G, B of each channel's standard deviation in the box (numpy std, population).
    static func colorSpread(_ img: Raster, _ box: [Int]) -> Double {
        let n = Double((box[2] - box[0]) * (box[3] - box[1]))
        guard n > 0 else { return 0 }
        var spread = 0.0
        for k in 0..<3 {
            var s = 0.0, s2 = 0.0
            for y in box[1]..<box[3] {
                for x in box[0]..<box[2] {
                    let v = Double(img.px[(y * img.w + x) * 3 + k])
                    s += v
                    s2 += v * v
                }
            }
            let mean = s / n
            spread += (max(0, s2 / n - mean * mean)).squareRoot()
        }
        return spread / 3
    }
}
