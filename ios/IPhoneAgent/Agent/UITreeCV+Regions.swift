import Foundation

/// Connected regions of a binary plane: each pass is one linear flood over flat buffers.
extension UITreeCV {

    /// 8-connected blobs of non-zero pixels, as [x1, y1, x2, y2], in raster order of their first pixel.
    static func components(_ p: Plane) -> [[Int]] {
        let w = p.w, h = p.h, n = w * h
        var seen = [UInt8](repeating: 0, count: n)
        var stack = [Int32](repeating: 0, count: max(1, n))  // every pixel is pushed at most once
        var out: [[Int]] = []
        p.v.withUnsafeBufferPointer { v in
            seen.withUnsafeMutableBufferPointer { seen in
                stack.withUnsafeMutableBufferPointer { st in
                    for start in 0..<n where v[start] != 0 && seen[start] == 0 {
                        var bx0 = start % w, by0 = start / w, bx1 = bx0, by1 = by0, top = 1
                        seen[start] = 1
                        st[0] = Int32(start)
                        while top > 0 {
                            top -= 1
                            let i = Int(st[top]), x = i % w, y = i / w
                            bx0 = min(bx0, x); by0 = min(by0, y); bx1 = max(bx1, x); by1 = max(by1, y)
                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let j = ny * w + nx
                                    if v[j] != 0 && seen[j] == 0 {
                                        seen[j] = 1
                                        st[top] = Int32(j)
                                        top += 1
                                    }
                                }
                            }
                        }
                        out.append([bx0, by0, bx1 + 1, by1 + 1])
                    }
                }
            }
        }
        return out
    }

    /// cv2.findContours(RETR_CCOMP)-like: for each 8-connected blob its outer contour and its holes (4-connected
    /// regions of other pixels inside it), each as a box and the contour's polygon area. Only blobs that keep()
    /// their outer box or are at least 40x24 are traced.
    static func contours(_ p: Plane, keep: ([Int]) -> Bool) -> [(box: [Int], area: Double)] {
        let w = p.w, h = p.h, n = w * h
        var label = [Int32](repeating: -1, count: n)
        var pixels = [Int32](repeating: 0, count: max(1, n))  // blob by blob
        var blobs: [(start: Int, end: Int, box: [Int])] = []
        p.v.withUnsafeBufferPointer { v in
            label.withUnsafeMutableBufferPointer { label in
                pixels.withUnsafeMutableBufferPointer { px in
                    var end = 0
                    for start in 0..<n where v[start] != 0 && label[start] < 0 {
                        let id = Int32(blobs.count), first = end
                        var bx0 = start % w, by0 = start / w, bx1 = bx0, by1 = by0, k = first
                        label[start] = id
                        px[end] = Int32(start)
                        end += 1
                        while k < end {
                            let i = Int(px[k]), x = i % w, y = i / w
                            k += 1
                            bx0 = min(bx0, x); by0 = min(by0, y); bx1 = max(bx1, x); by1 = max(by1, y)
                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let j = ny * w + nx
                                    if v[j] != 0 && label[j] < 0 {
                                        label[j] = id
                                        px[end] = Int32(j)
                                        end += 1
                                    }
                                }
                            }
                        }
                        blobs.append((first, end, [bx0, by0, bx1, by1]))
                    }
                }
            }
        }
        var out: [(box: [Int], area: Double)] = []
        var region: [Int32] = [], queue: [Int32] = []
        pixels.withUnsafeBufferPointer { px in
            for blob in blobs {
                let b = blob.box, outer = [b[0], b[1], b[2] + 1, b[3] + 1]
                guard keep(outer) || (outer[2] - outer[0] >= 40 && outer[3] - outer[1] >= 24) else { continue }
                let x0 = b[0] - 1, y0 = b[1] - 1, bw = b[2] - b[0] + 3, bh = b[3] - b[1] + 3, size = bw * bh
                if region.count < size {
                    region = [Int32](repeating: 0, count: size)
                    queue = region
                }
                var counts: [Int] = [], boxes: [[Int]] = []
                var touching: [Int] = []
                region.withUnsafeMutableBufferPointer { rg in
                    queue.withUnsafeMutableBufferPointer { q in
                        let mine: Int32 = -2, open: Int32 = -1  // the blob's own pixels / not yet in a region
                        for s in 0..<size { rg[s] = open }
                        for k in blob.start..<blob.end {
                            let i = Int(px[k])
                            rg[(i / w - y0) * bw + i % w - x0] = mine
                        }
                        for s in 0..<size where rg[s] == open {  // 4-connected regions of everything else in the box
                            let r = Int32(counts.count)
                            var head = 0, tail = 1, hx0 = bw, hy0 = bh, hx1 = -1, hy1 = -1
                            rg[s] = r
                            q[0] = Int32(s)
                            while head < tail {
                                let i = Int(q[head]), x = i % bw, y = i / bw
                                head += 1
                                hx0 = min(hx0, x); hy0 = min(hy0, y); hx1 = max(hx1, x); hy1 = max(hy1, y)
                                if x > 0 && rg[i - 1] == open { rg[i - 1] = r; q[tail] = Int32(i - 1); tail += 1 }
                                if x < bw - 1 && rg[i + 1] == open { rg[i + 1] = r; q[tail] = Int32(i + 1); tail += 1 }
                                if y > 0 && rg[i - bw] == open { rg[i - bw] = r; q[tail] = Int32(i - bw); tail += 1 }
                                if y < bh - 1 && rg[i + bw] == open { rg[i + bw] = r; q[tail] = Int32(i + bw); tail += 1 }
                            }
                            counts.append(tail)
                            boxes.append([hx0, hy0, hx1, hy1])
                        }
                        touching = [Int](repeating: 0, count: counts.count)
                        for k in blob.start..<blob.end {  // per blob pixel, each distinct region beside it once
                            let i = Int(px[k]), s = (i / w - y0) * bw + i % w - x0
                            let a = rg[s - 1], b = rg[s + 1], c = rg[s - bw], d = rg[s + bw]
                            if a >= 0 { touching[Int(a)] += 1 }
                            if b >= 0 && b != a { touching[Int(b)] += 1 }
                            if c >= 0 && c != a && c != b { touching[Int(c)] += 1 }
                            if d >= 0 && d != a && d != b && d != c { touching[Int(d)] += 1 }
                        }
                    }
                }
                if keep(outer) {  // outer contour: A = I + B/2 - 1 with I + B = the blob and all it encloses
                    let filled = size - counts[0]
                    out.append((outer, Double(filled) - Double(touching[0]) / 2 - 1))
                }
                for r in 1..<max(1, counts.count) {  // a hole: its pixels inside the traced blob pixels around it
                    let hb = boxes[r]
                    let box = [x0 + hb[0] - 1, y0 + hb[1] - 1, x0 + hb[2] + 2, y0 + hb[3] + 2]
                    if keep(box) { out.append((box, Double(counts[r]) + Double(touching[r]) / 2 - 1)) }
                }
            }
        }
        return out
    }
}
