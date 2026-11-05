import Foundation

/// What a run has collected so far: items read off the screen (deduplicated, in order), the actor's own notes and
/// one progress line. The model sees a short view of it every step, so a task that spans many screens ("the titles
/// of every video in my favorites") keeps what it read after the 8-step history has moved on.
struct Notebook: Equatable, Codable {
    private(set) var items: [String] = []
    private(set) var notes: [String] = []
    private(set) var progress = ""

    static let maxItems = 500
    static let maxItemChars = 200

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
            items.append(line)
            added += 1
        }
        return added
    }

    mutating func note(_ text: String) {
        let t = Self.clean(text)
        if !t.isEmpty, !notes.contains(t) { notes.append(t) }
    }

    mutating func setProgress(_ text: String) { progress = Self.clean(text) }

    /// The reader's reply as items: one per line, list markers and empty lines dropped; NONE means nothing.
    static func lines(_ reply: String) -> [String] {
        reply.components(separatedBy: .newlines).map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- ", "* ", "• "] where s.hasPrefix(marker) { s = String(s.dropFirst(marker.count)) }
            if let r = s.range(of: #"^\d{1,3}[.)、]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }.filter { !$0.isEmpty && $0.uppercased() != "NONE" }
    }

    /// For the actor's prompt: counts, progress, notes and the last few items (the full list is in the answer).
    func summary(lastItems: Int = 10) -> String {
        guard !isEmpty else { return "" }
        var out = "Notebook (\(items.count) item\(items.count == 1 ? "" : "s") collected"
        out += progress.isEmpty ? "):" : "; progress: \(progress)):"
        for n in notes.suffix(5) { out += "\n  note: " + n }
        if items.count > lastItems { out += "\n  …" }
        for (i, item) in items.enumerated().suffix(lastItems) { out += "\n  \(i + 1). " + item }
        return out
    }

    /// Everything collected, one item per line (written out by `write`, attached to the answer).
    var text: String { items.joined(separator: "\n") }

    private static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxItemChars))
    }

    /// Case- and space-insensitive, so "Title A" and "title  a" count as one item.
    private static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
