import CoreGraphics
import Foundation

/// `tap "删除"`: tap the words the model names, found by OCR on the screen as it is now, not a coordinate guess.
/// For buttons and rows read by their label (a list of 删除 / 确认 / 下一步 across runs), where the model's
/// coordinates drift by a row. One place showing the words: tapped there. None or several: nothing is sent and
/// the result says what was found, so the model taps by coordinates.
enum TapText {
    enum Found: Equatable {
        case at(x: Int, y: Int)
        case none
        case several([String])
    }

    /// Where `target` is among OCR `lines` (pixel boxes on an image of `size`), in 0-1000 units.
    /// A line that is exactly the words wins over lines that contain them; within a longer line the spot is
    /// the words' share of the line's width.
    static func find(_ target: String, in lines: [(text: String, box: [Int])], size: CGSize) -> Found {
        let found = match(target, in: lines, size: size)
        // a store name with its branch, "示例餐厅(中心店)": the card may show the name alone or cut it short
        if found == .none, let cut = target.firstIndex(where: { "(（[【".contains($0) }), target.distance(from: target.startIndex, to: cut) >= 2 {
            return match(String(target[..<cut]), in: lines, size: size)
        }
        return found
    }

    private static func match(_ target: String, in lines: [(text: String, box: [Int])], size: CGSize) -> Found {
        let want = norm(target)
        guard !want.isEmpty, size.width > 0, size.height > 0 else { return .none }
        let boxed = lines.filter { $0.box.count == 4 }
        let exact = boxed.filter { norm($0.text) == want }
        let hits = exact.isEmpty ? boxed.filter { norm($0.text).contains(want) } : exact
        let spots = hits.map { spot(want, $0, size) }
        guard let first = spots.first else { return .none }
        if spots.count > 1 { return .several(spots.prefix(4).map { "\($0.x) \($0.y)" }) }
        return .at(x: first.x, y: first.y)
    }

    static func result(_ target: String, _ found: Found) -> String? {
        switch found {
        case .at: return nil
        case .none: return "not sent: no \"\(target)\" read on this screen; tap it by coordinates"
        case .several(let at):
            return "not sent: \"\(target)\" shows in \(at.count) places (at \(at.joined(separator: ", "))); tap the one you mean by coordinates"
        }
    }

    private static func spot(_ want: String, _ line: (text: String, box: [Int]), _ size: CGSize) -> (x: Int, y: Int) {
        let b = line.box.map(Double.init)
        let text = norm(line.text)
        var x = (b[0] + b[2]) / 2
        if let r = text.range(of: want), text.count > want.count {
            let start = Double(text.distance(from: text.startIndex, to: r.lowerBound))
            x = b[0] + (b[2] - b[0]) * (start + Double(want.count) / 2) / Double(text.count)
        }
        var y = (b[1] + b[3]) / 2
        // a tab's label under its icon at the screen's foot: the tap goes on the icon (Henry 2026-11-18: a tap on
        // 订单's label at 963 left the home tab up; at 950 it opened the orders)
        if y > tabBar * size.height, text.count <= 4 { y = max(y - 1.5 * (b[3] - b[1]), tabBar * size.height) }
        return (Int(x / size.width * 1000), Int(y / size.height * 1000))
    }

    static let tabBar = 0.88  // below this share of the height: the tab bar

    /// Letters and digits only, full-width folded: OCR reads "(中心店)" as "（中心店）" or drops the brackets.
    static func norm(_ s: String) -> String {
        let folded = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        return String(folded.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

extension AgentLoop {
    /// A `tap "words"` gets its x y from the screen now; the reason it was not sent otherwise.
    /// `settleFirst`: an earlier tap of this round may still be moving the screen.
    func placeTextTap(_ act: inout JObject, settleFirst: Bool) async -> String? {
        guard act["action"]?.str == "tap", act["x"] == nil, let target = act["text"]?.str else { return nil }
        if settleFirst { _ = await settle() }
        // the look's own lines first: the screen the model chose on, read already (2026-11-19: a second read of the
        // full frame took 2.7 s before a tap). After an earlier tap of the round the screen may have moved: read again.
        if !settleFirst, let tree = lookTree,
           case .at(let x, let y) = TapText.find(target, in: tree.lines, size: CGSize(width: tree.w, height: tree.h)) {
            DebugLog.write("step: tap \"\(target)\" -> at(x: \(x), y: \(y)) from the look's lines")
            (act["x"], act["y"]) = (.int(x), .int(y))
            return nil
        }
        guard let frame = screen?.frame, let image = Vision.image(frame) else {
            return "not sent: no screen to read \"\(target)\" on; tap it by coordinates"
        }
        let lines = await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: target), whole: true)
        let found = TapText.find(target, in: lines, size: CGSize(width: image.width, height: image.height))
        DebugLog.write("step: tap \"\(target)\" -> \(found)")
        guard case .at(let x, let y) = found else { return TapText.result(target, found) }
        (act["x"], act["y"]) = (.int(x), .int(y))
        return nil
    }
}
