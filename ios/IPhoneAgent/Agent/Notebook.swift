import Foundation

/// What a run has collected so far: items read off the screen (deduplicated, in order), the actor's own notes and
/// one progress line. The model sees a short view of it every step, so a task that spans many screens ("the titles
/// of every video in my favorites") keeps what it read after the 8-step history has moved on.
struct Notebook: Equatable, Codable {
    private(set) var items: [String] = []
    private(set) var notes: [String] = []
    private(set) var progress = ""

    static let maxItems = 5000  // guards memory only; a cap users hit drops items silently (2026-11-19)
    static let maxItemChars = 1000  // a card with time, amount, start and end and a long address went over 200

    var isEmpty: Bool { items.isEmpty && notes.isEmpty && progress.isEmpty }

    /// Append what one screen showed. Two reads of a scrolled list overlap: the new read's first lines repeat the
    /// last ones already kept, so the longest such overlap is skipped; any other line already kept is skipped too.
    /// Returns how many items were new.
    @discardableResult
    mutating func add(_ lines: [String]) -> Int {
        let fresh = lines.map(Self.clean).filter { !$0.isEmpty }
        var overlap = 0
        for k in stride(from: min(fresh.count, items.count), to: 0, by: -1)
        where Array(items.suffix(k)).map(Self.key) == fresh.prefix(k).map(Self.key) {
            overlap = k
            break
        }
        var seen = Set(items.map(Self.key))
        var added = 0
        for line in fresh.dropFirst(overlap) where items.count < Self.maxItems && seen.insert(Self.key(line)).inserted {
            // the same item read again off a later screen, with its time: kept once, the fuller reading wins
            let t = Self.times(line)
            if !t.isEmpty, let i = items.firstIndex(where: { Self.times($0) == t }) {
                if Self.richer(line, than: items[i]) { items[i] = line }
                continue
            }
            items.append(line)
            added += 1
        }
        return added
    }

    func noted(_ text: String) -> Bool { notes.contains { Self.key($0) == Self.key(text) } }

    /// A note that completes an earlier one takes its place (Henry 2026-11-18: an order noted with "date: to find",
    /// then again with its date, showed up twice in notes.md).
    /// 2026-11-19: one order kept as four lines (with and without its shop, two ways of writing its address).
    mutating func note(_ text: String) {
        let t = Self.clean(text)
        guard !t.isEmpty, !noted(t) else { return }
        switch Self.place(t, in: notes) {
        case .new: notes.append(t)
        case .replaces(let i): notes[i] = t
        case .known: break
        }
    }

    enum Place: Equatable { case new, replaces(Int), known }

    /// Where a note goes among `notes`: a new item, in place of a line about the same item that says less, or nowhere
    /// (a line about that item already says as much).
    static func place(_ t: String, in notes: [String]) -> Place {
        guard let i = notes.firstIndex(where: { completes(t, $0) || sameItem(t, $0) }) else { return .new }
        return completes(t, notes[i]) || richer(t, than: notes[i]) ? .replaces(i) : .known
    }

    /// Two lines about one item: the same full time ("2026-11-12 23:10:00") and no other time, or, without times
    /// on both, the same name (first part) and amount.
    static func sameItem(_ a: String, _ b: String) -> Bool {
        let ta = times(a), tb = times(b)
        let pa = amounts(a), pb = amounts(b)
        if !pa.isEmpty, !pb.isEmpty, pa.isDisjoint(with: pb) { return false }
        if !ta.isEmpty, !tb.isEmpty { return ta == tb }
        return !pa.isEmpty && !pb.isEmpty && key(name(a)) == key(name(b)) && !key(name(a)).isEmpty
    }

    /// More parts (" · "), or as many and longer.
    static func richer(_ a: String, than b: String) -> Bool {
        let (na, nb) = (a.components(separatedBy: " · ").count, b.components(separatedBy: " · ").count)
        return na > nb || na == nb && a.count > b.count
    }

    private static func name(_ s: String) -> String {
        let first = s.components(separatedBy: " · ")[0]
        return amounts(first).isEmpty && times(first).isEmpty ? first : ""
    }

    private static func times(_ s: String) -> Set<String> {
        Set(s.matches(of: #/\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}(?::\d{2})?/#).map { String($0.0) })
    }

    /// Amounts: a number after ¥, or a part that is only a number with decimals ("24.8").
    private static func amounts(_ s: String) -> Set<String> {
        var out = Set(s.matches(of: #/[¥￥]\s*(\d+(?:\.\d+)?)/#).map { String($0.1) })
        for part in s.components(separatedBy: " · ") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.wholeMatch(of: #/\d+\.\d+/#) != nil { out.insert(p) }
        }
        return out
    }

    /// `new` says all `old` said and more: every number in `old` (amounts, times, counts) is in `new`, most of its
    /// words are, and `new` is longer. Two items that differ in any number (another order, another day) never match.
    static func completes(_ new: String, _ old: String) -> Bool {
        guard new.count > old.count else { return false }
        let numbers = { (s: String) in Set(s.matches(of: #/\d+(?:[.:]\d+)*/#).map { String($0.0) }) }
        let had = numbers(old)
        guard !had.isEmpty, had.isSubset(of: numbers(new)) else { return false }
        let pairs = { (s: String) -> Set<String> in
            let c = Array(s.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
            return c.count < 2 ? Set(c.map(String.init)) : Set((0..<c.count - 1).map { String(c[$0...$0 + 1]) })
        }
        let a = pairs(old), b = pairs(new)
        return !a.isEmpty && Double(a.intersection(b).count) / Double(a.count) >= 0.5
    }

    mutating func setProgress(_ text: String) { progress = Self.clean(text) }

    /// The count in the progress line: "3/12 orders", "folder 2 of 5", "第3/12", "3/?" (total unknown).
    var count: (done: Int, total: Int?)? { Self.count(progress) }

    static func count(_ text: String) -> (done: Int, total: Int?)? {
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"(\d+)\s*(?:/|／|of|out of)\s*(\d+|\?)"#, options: .caseInsensitive)
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let done = Int(ns.substring(with: m.range(at: 1))) else { return nil }
        let total = Int(ns.substring(with: m.range(at: 2)))
        return (done, total.flatMap { $0 > 0 ? $0 : nil })
    }

    /// The count reached its total: the goal's work is done, only the result is left to write.
    var reached: Bool { count.map { c in c.total.map { c.done >= $0 } ?? false } ?? false }

    /// The reader's reply as items: one per line, list markers and empty lines dropped; NONE means nothing.
    /// An item written over several lines (a block between empty lines, as "起点: …", "终点: …", "¥…") is one item,
    /// its lines joined by " · ": 2026-11-19 (Gaode rides), each line was kept as an item and a start shared by
    /// several rides was dropped as already seen, so the result had 2 of the rides.
    static func lines(_ reply: String) -> [String] {
        let rows = reply.components(separatedBy: .newlines).map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where s.hasPrefix(marker) { s = String(s.dropFirst(marker.count)) }
            if let r = s.range(of: #"^\d{1,3}[.)、]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }.filter { $0.uppercased() != "NONE" }
        var blocks: [[String]] = [[]]
        for row in rows { if row.isEmpty { blocks.append([]) } else { blocks[blocks.count - 1].append(row) } }
        return blocks.flatMap { block -> [String] in
            guard block.count > 1, block.contains(where: isField) else { return block }  // plain one-line items
            return splitRepeats(block).map { $0.joined(separator: " · ") }
        }
    }

    /// A block holding several items with no empty line between them: a field seen again starts the next item.
    private static func splitRepeats(_ block: [String]) -> [[String]] {
        var out: [[String]] = [[]], names = Set<String>()
        for row in block {
            let name = isField(row) ? String(row.prefix { $0 != ":" && $0 != "：" }).trimmingCharacters(in: .whitespaces) : nil
            if let name, names.contains(name) { out.append([]); names = [] }
            if let name { names.insert(name) }
            out[out.count - 1].append(row)
        }
        return out.filter { !$0.isEmpty }
    }

    /// "名称: 值", a field of a multi-line item.
    private static func isField(_ row: String) -> Bool {
        guard let colon = row.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        return row.distance(from: row.startIndex, to: colon) <= 12
    }

    static let maxEarlierNames = 60
    static let fullChars = 6000

    /// For the actor's prompt: counts, progress, notes and the last few items (the full list is in the answer).
    func summary(lastItems: Int = 10) -> String {
        guard !isEmpty else { return "" }
        // RECORD runs keep their records as notes, with no items: count those (2026-11-19: "0 items collected" over
        // 15 noted orders, and the model could not tell which orders were done)
        let counted = items.isEmpty && !notes.isEmpty ? "\(notes.count) note\(notes.count == 1 ? "" : "s")"
            : "\(items.count) item\(items.count == 1 ? "" : "s") collected"
        var out = "Notebook (" + counted
        out += progress.isEmpty ? "):" : "; progress: \(progress)):"
        if reached {  // the work is counted done: wrap up instead of looking for more
            out += "\n  The progress count is reached: finish now (write the result the goal asks for, then done)."
        }
        let earlier = notes.dropLast(5)
        if !earlier.isEmpty {  // their first field only (the item's name), so every noted item stays in view
            out += "\n  earlier notes (names): " + earlier.suffix(Self.maxEarlierNames)
                .map { $0.components(separatedBy: " · ")[0] }.joined(separator: "; ")
        }
        for n in notes.suffix(5) { out += "\n  note: " + n }
        // all of them while they fit: the model writes the result from this (2026-11-19: it saw the last 10 of 111)
        let shown = items.reduce(0) { $0 + $1.count } <= Self.fullChars ? items.count : lastItems
        if items.count > shown { out += "\n  …" }
        for (i, item) in items.enumerated().suffix(shown) { out += "\n  \(i + 1). " + item }
        return out
    }

    /// Everything collected, one item per line (written out by `write`, attached to the answer).
    var text: String { items.joined(separator: "\n") }

    private static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxItemChars))
    }

    /// Case-, space- and width-insensitive, so "Title A" and "title  a" count as one item, and so do "（东店）" and
    /// "(东店)" (2026-11-18: the record reader and the actor wrote one shop both ways, two notes).
    private static func key(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
