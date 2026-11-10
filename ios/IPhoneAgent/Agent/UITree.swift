import CoreGraphics
import Foundation
import ImageIO

/// Virtual UI tree of a screenshot, built on the phone: Apple Vision OCR lines plus classic CV regions,
/// nested by containment and XY-cut. Port of handsy-trial-gateway `handsy_trial/tree.py` (which runs PP-OCR
/// on Spark); keep the two in step so the benchmark numbers carry over (handsy-benchmark ondevice/arch).
/// The model gets the slim listing (`#ID role "label" at x y`) and may answer `tap #ID`.
final class UINode {
    var id = 0
    var role: String
    var label: String?
    var box: [Int]  // pixels [x1, y1, x2, y2]
    var near: String?
    var where_ = ""
    var children: [UINode]

    init(_ role: String, _ box: [Int], label: String? = nil, children: [UINode] = []) {
        self.role = role
        self.box = box
        self.label = label
        self.children = children
    }

    var json: JValue {
        var o: JObject = ["id": .int(id), "role": .str(role), "label": .str(label ?? ""),
                          "box": .arr(box.map { .int($0) }), "where": .str(where_)]
        if let near { o["near"] = .str(near) }
        if !children.isEmpty { o["children"] = .arr(children.map(\.json)) }
        return .obj(o)
    }
}

struct UITree {
    let w: Int, h: Int
    let nodes: [UINode]
    var lines: [(text: String, box: [Int])] = []  // the OCR input, for parity checks against tree.py
    var ocrSeconds = 0.0, cvSeconds = 0.0

    static let ocrPad = 3

    /// The tree of one frame (the 540-wide JPEG the model sees).
    static func build(jpeg: Data) async -> UITree? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let t0 = Date()
        let lines = await UITreeOCR.lines(image)
        let t1 = Date()
        guard let raster = Raster(image) else { return nil }
        var tree = build(raster, lines)
        tree.lines = lines
        tree.ocrSeconds = t1.timeIntervalSince(t0)
        tree.cvSeconds = Date().timeIntervalSince(t1)
        return tree
    }

    /// tree.py build() after OCR.
    static func build(_ img: Raster, _ lines: [(text: String, box: [Int])]) -> UITree {
        let W = img.w, H = img.h
        let textBoxes = lines.map(\.box)
        let edges = UITreeCV.edgeMap(img)
        var leaves = lines.map { UINode("text", $0.box, label: $0.text) }
        for (kind, b) in blobs(edges, textBoxes, W, H) where kind == "blob" {
            if Double(textBoxes.reduce(0) { $0 + inter(b, $1) }) < 0.5 * Double(area(b)) {
                leaves.append(UINode(classify(img, b, W), b))
            }
        }
        labelIcons(leaves)
        let rects = filledRects(edges, W, H).map { UINode("container", $0) }
        var top = prune(nest(rects, leaves), W, H)
        top = xyCut(top, [0, 0, W, H])
        finish(&top, W, H)
        for (i, n) in walk(top).enumerated() { n.id = i + 1 }
        return UITree(w: W, h: H, nodes: top)
    }

    // MARK: geometry

    static func area(_ b: [Int]) -> Int { max(0, b[2] - b[0]) * max(0, b[3] - b[1]) }
    static func inter(_ a: [Int], _ b: [Int]) -> Int {
        area([max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])])
    }
    static func inside(_ a: [Int], _ b: [Int], frac: Double = 0.85) -> Bool {
        area(a) > 0 && Double(inter(a, b)) >= frac * Double(area(a))
    }

    static func walk(_ nodes: [UINode]) -> [UINode] { nodes.flatMap { [$0] + walk($0.children) } }

    /// Python's sort is stable; Swift's is not.
    static func stableSorted<T, K: Comparable>(_ xs: [T], by key: (T) -> K) -> [T] {
        xs.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    // MARK: leaves and containers

    /// Non-text leaves: closed edge blobs with the text pixels removed.
    static func blobs(_ edges: Plane, _ textBoxes: [[Int]], _ W: Int, _ H: Int) -> [(String, [Int])] {
        var e = edges
        for b in textBoxes {
            for y in max(0, b[1] - ocrPad)..<min(H, b[3] + ocrPad) {
                for x in max(0, b[0] - ocrPad)..<min(W, b[2] + ocrPad) { e.v[y * W + x] = 0 }
            }
        }
        let closed = UITreeCV.close(UITreeCV.dilate(e, 3), 7)
        return UITreeCV.components(closed).compactMap { b in
            let w = b[2] - b[0], h = b[3] - b[1]
            if (Double(w) >= 0.9 * Double(W) && h <= 6) || (Double(h) >= 0.5 * Double(H) && w <= 6) { return ("separator", b) }
            if min(w, h) >= 12 && Double(w) <= 0.6 * Double(W) && Double(h) <= 0.35 * Double(H) { return ("blob", b) }
            return nil
        }
    }

    /// Containers: closed contours that are nearly rectangular and big enough to hold something.
    static func filledRects(_ edges: Plane, _ W: Int, _ H: Int) -> [[Int]] {
        let closed = UITreeCV.close(edges, 3)
        let found = UITreeCV.contours(closed) { b in
            let w = b[2] - b[0], h = b[3] - b[1]
            return w >= 40 && h >= 24 && Double(w * h) <= 0.6 * Double(W * H)
        }
        let rects = found.filter { $0.area / Double(area($0.box)) >= 0.8 }.map(\.box)
        var keep: [[Int]] = []  // drop near-duplicates (inner/outer stroke of the same rectangle)
        for b in stableSorted(rects, by: { -area($0) }) where !keep.contains(where: {
            Double(inter(b, $0)) > 0.9 * Double(area(b)) && Double(area($0)) < 1.2 * Double(area(b))
        }) {
            keep.append(b)
        }
        return keep
    }

    static func classify(_ img: Raster, _ box: [Int], _ W: Int) -> String {
        let w = Double(box[2] - box[0]), h = Double(box[3] - box[1])
        if (1.6...2.4).contains(w / h) && h <= 50 { return "control" }  // switch / toggle shape
        if max(w, h) >= 0.22 * Double(W) && UITreeCV.colorSpread(img, box) > 25 { return "image" }
        return "icon"
    }

    /// An icon with no text takes the text right below it (app icon name) or the row text beside it.
    static func labelIcons(_ leaves: [UINode]) {
        let texts = leaves.filter { $0.role == "text" }
        for n in leaves where ["icon", "image", "control"].contains(n.role) {
            let b = n.box, cx = Double(b[0] + b[2]) / 2, h = Double(b[3] - b[1])
            if let t = texts.first(where: {
                Double($0.box[1] - b[3]) >= 0 && Double($0.box[1] - b[3]) <= 0.6 * h && Double($0.box[0]) <= cx && cx <= Double($0.box[2])
            }) {
                n.label = t.label
                n.near = "below"
                continue
            }
            let mid = Double(b[1] + b[3]) / 2
            let side = texts.filter { abs(Double($0.box[1] + $0.box[3]) / 2 - mid) < max(h, 20) / 2 + 6 }
            let gap = { (t: UINode) in min(abs(t.box[0] - b[2]), abs(b[0] - t.box[2])) }
            if let t = side.min(by: { gap($0) < gap($1) }) {
                n.label = t.label
                n.near = "beside"
            }
        }
    }

    // MARK: structure

    /// Attach each node to the smallest container that holds it; returns the top-level list.
    static func nest(_ parents: [UINode], _ leaves: [UINode]) -> [UINode] {
        let items = stableSorted(parents + leaves) { -area($0.box) }
        var top: [UINode] = []
        for (i, n) in items.enumerated() {
            var holder: UINode?
            for p in items[..<i] where p.role == "container" && p !== n && inside(n.box, p.box) {
                if holder == nil || area(p.box) < area(holder!.box) { holder = p }
            }
            if let holder { holder.children.append(n) } else { top.append(n) }
        }
        return top
    }

    /// A container must hold something, and not just one leaf the same size as itself.
    static func prune(_ nodes: [UINode], _ W: Int, _ H: Int) -> [UINode] {
        var out: [UINode] = []
        for n in nodes {
            guard n.role == "container" else { out.append(n); continue }
            n.children = prune(n.children, W, H)
            if n.children.isEmpty {
                if Double(area(n.box)) < 0.02 * Double(W * H) {
                    n.role = "button"  // empty filled rect: a shape button / field
                    out.append(n)
                }
                continue
            }
            if n.children.count == 1 && Double(area(n.children[0].box)) > 0.6 * Double(area(n.box)) {
                out.append(n.children[0])
                continue
            }
            n.children = xyCut(n.children, n.box)
            out.append(n)
        }
        return out
    }

    /// Group nodes by whitespace gaps, alternating horizontal and vertical cuts.
    static func xyCut(_ nodes: [UINode], _ box: [Int], depth: Int = 0, horizontal: Bool = true) -> [UINode] {
        guard nodes.count > 1, depth <= 6 else { return nodes }
        for (lo, hi) in horizontal ? [(1, 3), (0, 2)] : [(0, 2), (1, 3)] {
            let spans = nodes.map { ($0.box[lo], $0.box[hi]) }.sorted { $0 < $1 }
            var cuts: [Double] = [], end = spans[0].1
            for (s, e) in spans.dropFirst() {
                if s > end + 4 { cuts.append(Double(end + s) / 2) }
                end = max(end, e)
            }
            guard !cuts.isEmpty else { continue }
            var groups = [[UINode]](repeating: [], count: cuts.count + 1)
            for n in nodes {
                let c = Double(n.box[lo] + n.box[hi]) / 2
                groups[cuts.filter { c > $0 }.count].append(n)
            }
            let role = lo == 1 ? "row" : "cell"
            var out: [UINode] = []
            for g in groups {
                if g.count == 1 { out.append(g[0]); continue }
                if g.isEmpty { continue }  // tree.py: an empty group is never made (every cut has nodes on both sides)
                var gb = [g.map { $0.box[0] }.min()!, g.map { $0.box[1] }.min()!, g.map { $0.box[2] }.max()!, g.map { $0.box[3] }.max()!]
                // a row spans its parent's width, a cell its parent's height (tap anywhere on a list row)
                let (ca, cb) = lo == 1 ? (0, 2) : (1, 3)
                gb[ca] = box[ca]
                gb[cb] = box[cb]
                out.append(UINode(role, gb, children: xyCut(g, gb, depth: depth + 1, horizontal: lo != 1)))
            }
            if lo == 1 && depth == 0 { out += blanks(spans, box) }
            return out
        }
        return nodes
    }

    /// Large empty bands (a blank note body, empty space) are tappable nodes too.
    static func blanks(_ spans: [(Int, Int)], _ box: [Int], minGap: Double = 0.08) -> [UINode] {
        let H = Double(box[3] - box[1])
        var out: [UINode] = [], end = Double(box[1])
        for (s, e) in spans + [(box[3], box[3])] {
            if Double(s) - end >= minGap * H {
                out.append(UINode("blank", [box[0], Int(end), box[2], s], label: "empty area"))
            }
            end = max(end, Double(e))
        }
        return out
    }

    static func whereWords(_ b: [Int], _ W: Int, _ H: Int) -> String {
        let cx = Double(b[0] + b[2]) / 2 / Double(W), cy = Double(b[1] + b[3]) / 2 / Double(H)
        let v = cy < 0.15 ? "top" : cy > 0.85 ? "bottom" : cy < 0.45 ? "upper" : cy > 0.6 ? "lower" : "middle"
        return v + " " + (cx < 0.33 ? "left" : cx > 0.67 ? "right" : "center")
    }

    /// Reading order, container labels from their text, position words.
    static func finish(_ nodes: inout [UINode], _ W: Int, _ H: Int) {
        // key (round(y1 / 12), x1); Python rounds half to even
        nodes = stableSorted(nodes) { (Double($0.box[1]) / 12).rounded(.toNearestOrEven) * 100_000 + Double($0.box[0]) }
        for n in nodes {
            finish(&n.children, W, H)
            if n.label == nil {
                let words = walk(n.children).filter { $0.role == "text" }.compactMap(\.label)
                n.label = String(String.UnicodeScalarView(words.joined(separator: " ").unicodeScalars.prefix(80)))
            }
            n.where_ = whereWords(n.box, W, H)
        }
    }

    // MARK: what the model sees

    /// handsy_trial.treetext.candidates minus layout rows / cells: what `#ID` numbers.
    var elements: [UINode] { candidates.filter { $0.role != "row" && $0.role != "cell" } }

    /// handsy_trial.treetext.candidates itself: what Spark's listing numbers, rows and cells included.
    var candidates: [UINode] {
        Array(Self.walk(nodes).filter { Double(Self.area($0.box)) < 0.4 * Double(w * h) }.prefix(150))
    }

    func point(_ n: UINode) -> (Int, Int) {
        (Int(Double(n.box[0] + n.box[2]) / 2 * 1000 / Double(w)), Int(Double(n.box[1] + n.box[3]) / 2 * 1000 / Double(h)))
    }

    /// Appended to the actor's user text (handsy-benchmark ondevice/arch/run_slim.py).
    var listing: String {
        let lines = elements.enumerated().map { i, n in
            let (x, y) = point(n)
            let label = String(String.UnicodeScalarView((n.label ?? "").unicodeScalars.prefix(40)))
            return "#\(i + 1) \(n.role) \"\(label)\" at \(x) \(y)"
        }
        return "\n\nScreen elements (id, role, label, center x y in 0-1000):\n" + lines.joined(separator: "\n")
            + "\nTo tap one of these you may write: tap #ID"
    }

    /// "tap #12" -> "tap 503 871" (this frame's element 12); an unknown id is left as it is (the parser rejects it).
    /// `spark`: the ids of Spark's listing, numbered over `candidates` (treetext.by_listing_id); the app's own
    /// `listing` numbers `elements`. Resolving Spark's ids over `elements` was off by the rows/cells before the id
    /// (2026-11-11).
    func resolve(_ reply: String, spark: Bool = false) -> String {
        let ids = spark ? candidates : elements
        let pattern = try! NSRegularExpression(pattern: "(?im)^(\\s*DO\\s*[:：]\\s*tap\\s+)#(\\d+)")
        var out = reply
        for m in pattern.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)).reversed() {
            guard let r = Range(m.range(at: 2), in: reply), let i = Int(reply[r]), (1...ids.count).contains(i),
                  let whole = Range(NSRange(location: m.range(at: 2).location - 1, length: m.range(at: 2).length + 1), in: out)
            else { continue }
            let (x, y) = point(ids[i - 1])
            out.replaceSubrange(whole, with: "\(x) \(y)")
        }
        return out
    }

    /// {w, h, ocr, tree}: the shape handsy_trial.treetext reads (benchmark trees, debugging).
    var json: JValue {
        .obj(["w": .int(w), "h": .int(h), "ocr": .str("vision"), "tree": .arr(nodes.map(\.json))])
    }
}

extension UITree {
    /// The tree Spark built for the sent frame (the free line's `handsy.tree`, X-Handsy-Tree: slim): the shape
    /// `json` writes, so `elements`, `listing` and `resolve` number exactly what Spark listed for the model.
    init?(json: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let w = o["w"] as? Int, let h = o["h"] as? Int, w > 0, h > 0, let nodes = o["tree"] as? [[String: Any]]
        else { return nil }
        func node(_ d: [String: Any]) -> UINode? {
            guard let role = d["role"] as? String, let box = d["box"] as? [Int], box.count == 4 else { return nil }
            let children = (d["children"] as? [[String: Any]] ?? []).compactMap(node)
            let n = UINode(role, box, label: d["label"] as? String, children: children)
            n.id = d["id"] as? Int ?? 0
            n.near = d["near"] as? String
            n.where_ = d["where"] as? String ?? ""
            return n
        }
        self.init(w: w, h: h, nodes: nodes.compactMap(node))
    }
}
