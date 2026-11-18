import Foundation

/// A note's amounts are checked against the page it was noted from (its screens since it opened, scrolls
/// included). Henry 2026-11-18: a run noted an order with another card's amount. Any app, any task: the note is
/// always kept, and an amount the page did not show is pointed out in the step's result, never refused (a refusal
/// left the page mid-reply and the run went round its cards).
enum NoteCheck {
    static let pageScreens = 6  // screens of one page kept

    /// Amounts in a note: decimals (21.70) and numbers after a currency sign (¥30).
    static func amounts(_ text: String) -> [String] {
        let flat = text.replacingOccurrences(of: ",", with: "")
        let decimals = flat.matches(of: #/\d+\.\d{1,2}/#).map { String($0.0) }
        let priced = flat.matches(of: #/[¥￥$€£]\s*(\d+(?:\.\d{1,2})?)/#).map { String($0.1) }
        return Array(Set(decimals + priced)).sorted()
    }

    static func missing(_ note: String, screen lines: [String]) -> [String] { missing(amounts(note), screen: lines) }

    /// The amounts the screen's text does not hold.
    static func missing(_ amounts: [String], screen lines: [String]) -> [String] {
        let shown = lines.joined(separator: " ").replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        return amounts.filter { !shown.contains($0) }
    }

    /// The names in a note (a shop, a hotel, a route): parts between separators with no digits and at least 4
    /// letters. 2026-11-18: an order noted with the first order's shop and its own amount; only the amount was checked.
    static func names(_ text: String) -> [String] {
        text.split(whereSeparator: { "·•|,，;；、\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in !part.contains(where: \.isNumber) && letters(part).count >= 4 }
    }

    /// A name counts as seen when most of its letter pairs are on the screen (OCR drops or swaps a character).
    static func unseenNames(_ names: [String], screen lines: [String]) -> [String] {
        let shown = pairs(letters(lines.joined()))
        return names.filter { name in
            let own = pairs(letters(name))
            return !own.isEmpty && Double(own.intersection(shown).count) / Double(own.count) < 0.7
        }
    }

    private static func letters(_ s: String) -> [Character] { s.lowercased().filter { $0.isLetter } }
    private static func pairs(_ c: [Character]) -> Set<String> {
        c.count < 2 ? [] : Set((0..<c.count - 1).map { String(c[$0...$0 + 1]) })
    }

    /// A day in a text: (month, day) of "2026年11月9日", "11月09日", "2026-11-15", "11-15", "11/15". `text`: as written.
    struct Day: Comparable, Hashable {
        let month: Int, day: Int
        var text = ""
        static func < (a: Day, b: Day) -> Bool { (a.month, a.day) < (b.month, b.day) }
        static func == (a: Day, b: Day) -> Bool { a.month == b.month && a.day == b.day }
        func hash(into h: inout Hasher) { h.combine(month); h.combine(day) }
    }

    /// The days a text names. A time ("20:14") or an amount is never a day; "10-15 至 10-16" gives both.
    static func days(_ text: String) -> [Day] {
        var out: [Day] = []
        let ns = text as NSString
        for p in dayPatterns {
            for m in p.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let mo = Int(ns.substring(with: m.range(at: 1))), let d = Int(ns.substring(with: m.range(at: 2))),
                      (1...12).contains(mo), (1...31).contains(d) else { continue }
                let day = Day(month: mo, day: d, text: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces))
                if !out.contains(day) { out.append(day) }
            }
        }
        return out
    }
    private static let dayPatterns = [
        #"(?<!\d)(?:20\d\d\s*年)?\s*(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#,
        #"(?<![\d.:])(?:20\d\d-)?(\d{1,2})-(\d{1,2})(?![\d.:])"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// The note's days the screen does not show. 2026-11-18: an order noted "11月09日", the goal's first day; its
    /// page showed no date at all.
    static func unseenDays(_ days: [Day], screen lines: [String]) -> [Day] {
        let shown = Set(Self.days(lines.joined(separator: " ")))
        return days.filter { !shown.contains($0) }
    }

    /// The goal's date range: two days ("11月9日到11月15日"), or one day and "since"/"to today" (到今天, 之后, 以来, 起,
    /// since, after): from that day to `today`. nil: the goal names no range.
    static func range(_ goal: String, today: Date = Date()) -> ClosedRange<Day>? {
        let named = days(goal)
        if named.count >= 2 { return min(named[0], named[1])...max(named[0], named[1]) }
        guard let start = named.first else { return nil }
        let lower = goal.lowercased()
        guard ["到今天", "至今", "之后", "以后", "以来", "起", "since", "after", "until today", "to today"].contains(where: lower.contains)
        else { return nil }
        let c = Calendar.current.dateComponents([.month, .day], from: today)
        let end = Day(month: c.month ?? 12, day: c.day ?? 31)
        return start <= end ? start...end : nil
    }

    /// A note whose days all fall outside the goal's range: what to tell the model, else nil.
    static func outside(_ note: String, goal: String, today: Date = Date()) -> String? {
        guard let range = range(goal, today: today) else { return nil }
        let days = days(note)
        guard !days.isEmpty, days.allSatisfy({ !range.contains($0) }) else { return nil }
        return "; \(days.map(\.text).joined(separator: ", ")) is outside the goal's dates "
            + "(\(range.lowerBound.month)-\(range.lowerBound.day) to \(range.upperBound.month)-\(range.upperBound.day)): "
            + "this item does not count; leave it out of the result"
            + (days.allSatisfy({ $0 < range.lowerBound }) ? Self.pastStart : "")
    }

    /// An item older than the goal's first day. Lists are not always strictly by time (2026-11-19, Meituan: orders
    /// of 11-07 and 11-08 sat among those of 11-16), so one old item is skipped; two or three in a row end the list.
    static let pastStart = ". Skip it and go on; when the next two or three items are older too, the list has passed "
        + "the goal's dates: write the result and finish"

    /// The note's days, when every one is before the goal's first day.
    static func beforeStart(_ note: String, goal: String, today: Date = Date()) -> Bool {
        guard let range = range(goal, today: today) else { return false }
        let days = days(note)
        return !days.isEmpty && days.allSatisfy { $0 < range.lowerBound }
    }

    static func warning(_ missing: [String]) -> String {
        "; check it: \(missing.joined(separator: ", ")) was not seen on this page. If it is from another item, note "
            + "this item again with what its page shows"
    }
}
