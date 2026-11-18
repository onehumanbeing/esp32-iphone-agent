import CoreGraphics
import Foundation

/// `each "已完成" read "店名, 金额, 下单时间" [max N]`: a list worked item by item by code. Each card on the list shows
/// the ANCHOR words once; the code taps them (opening that item), reads WHAT off the item's screen into the notebook
/// and notes.md (with that screen), goes back, and takes the next card down, scrolling when the screen's cards are
/// done. Henry 2026-11-18: an order took the model 4-6 steps (open, read, note, back, find the next) at ~14.5 s
/// each; here it is a tap, one reader call and a back. Read-only: never an anchor that pays or deletes.
/// - ANCHOR ending in `*` matches words that start with it and differ per card: `"¥*"` taps each card's price
///   (2026-11-18: on a food-order list only the price opens the order; the status sits in the row that opens the shop).
/// - `open "X"` taps X on the item's page before reading (scrolling down to it): details folded under "查看更多".
enum Each {
    static let maxItems = 300, defaultItems = 10  // 30 cut a 50-order list silently (no product-breaking caps, 2026-11-19)
    static let dry = 2  // scrolls in a row that bring no new card
    static let top = 0.10, bottom = 0.90  // cards outside this band may be cut off by bars or the screen edge

    struct Order: Equatable {
        var anchor: String
        var what: String
        var max: Int
        var open: String? = nil
    }

    struct Card: Equatable {
        var x: Int, y: Int  // 0-1000
        var key: String     // the card's own words, to know it again after a scroll
    }

    enum End: String {
        case max = "the item limit"
        case dry = "2 scrolls in a row brought no new item"
        case still = "the list stopped moving (its end)"
        case unopened = "tapping the item did not open anything"
        case unread = "nothing to read on the item's screen (it may not be the item page)"
        case lost = "after going back the list was not there"
        case limit = "the app limits how often this can be done"
        case paying = "the anchor words pay or delete"
        case feed = "a recommendations feed starts (the list's own end)"
    }

    /// `"ANCHOR" read "WHAT" [max N]`; nil when the anchor or WHAT is missing. With RECORD (`record` = its
    /// fields) WHAT may be left out: the record reader reads those fields off each item.
    static func parse(_ rest: String, record: [String] = []) -> Order? {
        var rest = rest
        let open = rest.firstMatch(of: #/open\s+"([^"]+)"/#)
        let words = open.map { String($0.1) }
        if let open { rest.removeSubrange(open.range) }
        let quoted = rest.matches(of: #/"([^"]+)"/#).map { String($0.1) }
        let what = quoted.count >= 2 ? quoted[1] : record.isEmpty ? nil : record.joined(separator: ", ")
        guard let anchor = quoted.first, let what else { return nil }
        let n = rest.firstMatch(of: #/max\s+(\d+)/#).flatMap { Int($0.1) } ?? defaultItems
        return Order(anchor: anchor, what: what, max: min(Swift.max(n, 1), maxItems), open: words)
    }

    /// The anchor's words, and whether more may follow them (a trailing `*`). A prefix keeps its signs ("¥").
    static func pattern(_ anchor: String) -> (words: String, prefix: Bool) {
        let t = anchor.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("*") ? (fold(String(t.dropLast())), true) : (TapText.norm(t), false)
    }

    static func matches(_ text: String, _ anchor: String) -> Bool {
        let (want, prefix) = pattern(anchor)
        guard prefix else { return TapText.norm(text).contains(want) }
        let have = fold(text)
        return have.hasPrefix(want) && have.count > want.count
    }

    /// Half-width, lower case, no spaces: "￥ 75.4" and "¥75.4" are the same.
    static func fold(_ s: String) -> String {
        let folded = (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
        return String(folded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The cards on a screen: each line holding the anchor (top to bottom, inside the content band), keyed by the
    /// words on its row and the two lines under it.
    static func cards(_ anchor: String, in lines: [(text: String, box: [Int])], size: CGSize) -> [Card] {
        guard !pattern(anchor).words.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let boxed = lines.filter { $0.box.count == 4 }.sorted { $0.box[1] < $1.box[1] }
        return boxed.compactMap { line -> Card? in
            guard matches(line.text, anchor) else { return nil }
            let (b, h) = (line.box, Double(line.box[3] - line.box[1]))
            let cy = Double(b[1] + b[3]) / 2
            guard cy > top * size.height, cy < bottom * size.height else { return nil }
            let row = boxed.filter { abs(Double($0.box[1] + $0.box[3]) / 2 - cy) < Swift.max(h, 8) && $0.text != line.text }
            let below = boxed.filter { Double($0.box[1]) > cy + h / 2 }.prefix(2)
            // the card's own words first: rows below (buttons) can be the same on every card
            let key = ([line] + row + below).map { TapText.norm($0.text) }.joined(separator: "|")
            guard case .at(let x, let y) = TapText.find(pattern(anchor).prefix ? line.text : anchor, in: [line], size: size)
            else { return nil }
            return Card(x: x, y: y, key: key.isEmpty ? "\(x),\(y)" : key)
        }
    }

    /// The first card not done yet.
    static func next(_ cards: [Card], done: Set<String>) -> Card? { cards.first { !done.contains($0.key) } }
}

extension AgentLoop {
    func each(_ act: inout JObject) async throws {
        guard let phone else { throw LLMError(message: "no phone") }
        let fields = reader == nil ? [] : recordFields
        guard let order = Each.parse(act["text"]?.str ?? "", record: fields) else {
            act["reason"] = .str("not run: write each \"ANCHOR\" read \"WHAT\" [max N]")
            return
        }
        var again = 0  // items opened that the notebook already had (a resumed run, a list that moved)
        // the first each of an order does one item and hands back: the model checks what was read, then sends the
        // same each again for the rest (Henry 2026-11-18: verify one round before the loop)
        let orderKey = order.anchor + "|" + order.what
        let checked = eachChecked.contains(orderKey)
        let limit = checked ? order.max : 1
        var done = eachDone, read: [String] = []
        var (dryRun, seconds) = (0, 0.0)
        var end = Each.End.max
        if PayGuard.kind(order.anchor) != nil { end = .paying } else {
            loop: while read.count < limit && again < order.max {
                try await gate?()
                _ = await settle()
                let (lines, size) = await screenLines(order.anchor)
                if RateLimit.shown(lines.map(\.text), before: []) != nil { end = .limit; break }
                guard let card = Each.next(Each.cards(order.anchor, in: lines, size: size), done: done) else {
                    if Feed.header(lines.map(\.text)) != nil { end = .feed; break }
                    let before = screen?.frame
                    try await phone.swipe(Collect.from.x, Collect.from.y, Collect.to.x, Collect.to.y, hold: true)
                    lastActed = now()
                    _ = await settle()
                    let after = screen?.frame, pointer = pointerAt
                    if !(await Vision.off { Vision.changed(before, after, ignore: [pointer]) }) { end = .still; break }
                    dryRun += 1
                    if dryRun >= Each.dry { end = .dry; break }
                    continue
                }
                dryRun = 0
                done.insert(card.key)
                let list = screen?.frame
                _ = try await perform(["action": .str("tap"), "x": .int(card.x), "y": .int(card.y)])
                lastActed = now()
                _ = await settle()
                let opened = screen?.frame, pointer = pointerAt
                guard await Vision.off({ Vision.changed(list, opened, ignore: [pointer]) }) else { end = .unopened; break }
                if let open = order.open { await expand(open) }
                let started = now()
                if !fields.isEmpty {
                    // RECORD: the record reader reads this item and keeps it with its screen (notes.md)
                    switch await recordNow() {
                    case .none: end = .unread; break loop
                    case .already:
                        again += 1
                        DebugLog.write("each: \"\(card.key.prefix(40))\" was already in the notebook")
                    case .kept: read.append(String(card.key.prefix(30)))
                    }
                    seconds += now() - started
                } else {
                    let (got, _, s) = try await readScreen(order.what)
                    seconds += s
                    guard got > 0 else { end = .unread; break }
                    read.append(String(card.key.prefix(30)))
                }
                DebugLog.write("each: item \(read.count) \"\(card.key.prefix(40))\" read in \(String(format: "%.1f", now() - started)) s")
                _ = try await backChecked()
                lastActed = now()
                _ = await settle()
                let (back, backSize) = await screenLines(order.anchor)
                if Each.cards(order.anchor, in: back, size: backSize).isEmpty {
                    end = .lost
                    break loop
                }
            }
        }
        eachDone = done
        if !checked, read.count == 1, end == .max {
            eachChecked.insert(orderKey)
            DebugLog.write("each: first item done, handed back to check")
            act["reason"] = .str("each \"\(order.anchor)\": first item opened and read, back on the list. Check it in the "
                                 + "notebook: if it has \(order.what), give the same each line again to do the rest; if a fact "
                                 + "is folded, add open \"X\"; if the item's page does not have it at all, go on without it")
            return
        }
        DebugLog.write("each: \(read.count) items, stopped: \(end.rawValue)")
        act["think_s"] = .num((seconds * 100).rounded() / 100)
        let total = fields.isEmpty ? notebook.items.count : notebook.notes.count
        act["reason"] = .str("each \"\(order.anchor)\": \(read.count) item\(read.count == 1 ? "" : "s") opened and read"
                             + (again > 0 ? ", \(again) opened that were already noted" : "")
                             + "; \(total) in the notebook; stopped: \(end.rawValue)")
    }

    /// OCR lines of the screen now, in pixels, and the image size.
    /// `open "X"` of an each line: find X on the item's page (scrolling down), tap it. Not found: read what shows.
    private func expand(_ words: String) async {
        var probe: JObject = ["text": .str(words)]
        try? await find(&probe)
        let (lines, size) = await screenLines(words)
        guard case .at(let x, let y) = TapText.find(words, in: lines, size: size) else {
            DebugLog.write("each: \"\(words)\" not on the item's page; reading what shows")
            return
        }
        _ = try? await perform(["action": .str("tap"), "x": .int(x), "y": .int(y)])
        lastActed = now()
        _ = await settle()
    }

    private func screenLines(_ words: String) async -> ([(text: String, box: [Int])], CGSize) {
        guard let frame = screen?.frame, let image = Vision.image(frame) else { return ([], .zero) }
        let lines = await UITreeOCR.lines(image, languages: UITreeOCR.languages(for: words), whole: true)
        return (lines, CGSize(width: image.width, height: image.height))
    }
}
