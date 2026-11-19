import Foundation

/// How far a scroll really moved the page. Henry 2026-11-18: swipes ran on past where they stopped (the list kept
/// gliding), so the model jumped over the next card, scrolled back, and went up and down. After a vertical swipe the
/// lines seen on both screens give the page's shift; the step says how far it went for how far the finger went, and
/// later swipes are cut shorter while this phone's lists run on (`gain`).
enum ScrollMeter {
    static let ranOn = 1.4       // moved / swiped above this: the page glided on
    static let minLines = 2      // lines on both screens needed to measure

    /// The page's upward shift in 0-1000 of the screen height: the median shift of lines that show once on each
    /// screen and moved. nil when fewer than `minLines` such lines are on both (the page moved a screen or more,
    /// or changed).
    static func moved(_ before: [(text: String, box: [Int])], _ after: [(text: String, box: [Int])], height: Double) -> Double? {
        guard height > 0 else { return nil }
        func centers(_ lines: [(text: String, box: [Int])]) -> [String: Double] {
            var seen: [String: Double] = [:], twice: Set<String> = []
            for line in lines where line.box.count == 4 && line.text.count >= 2 {
                let y = Double(line.box[1] + line.box[3]) / 2
                if seen[line.text] != nil { twice.insert(line.text) } else { seen[line.text] = y }
            }
            return seen.filter { !twice.contains($0.key) }
        }
        let a = centers(before), b = centers(after)
        // the bars that stay put (a title, the tabs) are not the page: lines that did not move are left out
        let shifts = a.compactMap { text, y in b[text].map { y - $0 } }.filter { abs($0) > height * 0.01 }.sorted()
        guard shifts.count >= minLines else { return nil }
        return shifts[shifts.count / 2] / height * 1000
    }

    /// The swipe's vertical length (0-1000, positive up), nil for a sideways one.
    static func swiped(_ act: JObject) -> Double? {
        guard let x1 = act["x1"]?.double, let y1 = act["y1"]?.double, let x2 = act["x2"]?.double, let y2 = act["y2"]?.double,
              abs(y2 - y1) > abs(x2 - x1), abs(y2 - y1) >= 50 else { return nil }
        return y1 - y2
    }

    /// What to tell the model, nil when the page moved about as far as the finger.
    static func result(swiped: Double, moved: Double?) -> String? {
        guard let moved else {
            return "this scroll moved the page more than a screen (nothing from before is still on screen): "
                + "you may have passed items; scroll back up a little and swipe shorter"
        }
        guard abs(moved) > abs(swiped) * ranOn else { return nil }
        return "the page glided on: it moved \(Int(abs(moved))) for a \(Int(abs(swiped))) swipe; swipe shorter "
            + "(next swipes are cut shorter)"
    }

    /// The running ratio moved / swiped (1 = no glide), a slow average so one odd screen does not swing it.
    static func gain(_ old: Double, swiped: Double, moved: Double?) -> Double {
        let ratio = moved.map { max(1, min(3, abs($0) / max(abs(swiped), 1))) } ?? 2
        return old * 0.6 + ratio * 0.4
    }
}
