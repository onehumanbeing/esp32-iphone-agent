import Foundation

/// One remembered line: a preference or fact the user told the agent, or how something works in an app.
struct MemoryEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case preference, fact, app }

    var id: String
    var date: Date
    var kind: Kind
    var topic: String
    var text: String
}

/// Long-term memory as plain Markdown, in the layout pi-memory uses (`MEMORY.md`), so a computer-side agent can read
/// the same file:
///
///     <!-- 2026-11-02 10:12:03 [a1b2c3d4] -->
///     #preference [[bilibili]] Favorites are under Me › Favorites.
///
/// Only the user's own words and lessons from finished runs are kept; passwords, codes and card numbers never are.
/// A new task recalls the few entries most like its text (character bigrams, no embeddings).
@MainActor final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var entries: [MemoryEntry] = []
    let file: URL

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memory/MEMORY.md")
        entries = Self.parse((try? String(contentsOf: self.file, encoding: .utf8)) ?? "")
    }

    /// Adds an entry unless it is empty, sensitive or already known. Returns the entry kept, if any.
    @discardableResult
    func add(_ text: String, kind: MemoryEntry.Kind, topic: String = "") -> MemoryEntry? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty, text.count <= 300, !Self.sensitive(text) else { return nil }
        guard !entries.contains(where: { $0.text.lowercased() == text.lowercased() }) else { return nil }
        let entry = MemoryEntry(id: String(UUID().uuidString.lowercased().prefix(8)), date: Date(), kind: kind,
                                topic: Self.topicSlug(topic), text: text)
        entries.append(entry)
        save()
        return entry
    }

    func update(_ id: String, text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }), !Self.sensitive(text) else { return }
        entries[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// The entries most related to a task, best first. Preferences always count a little: they apply broadly.
    func recall(_ query: String, limit: Int = 5) -> [MemoryEntry] {
        let q = Self.bigrams(query)
        return entries.map { e -> (MemoryEntry, Double) in
            var score = Self.similarity(q, Self.bigrams(e.text + " " + e.topic))
            if !e.topic.isEmpty, query.lowercased().contains(e.topic.replacingOccurrences(of: "-", with: " ")) { score += 0.5 }
            if e.kind == .preference { score += 0.02 }
            return (e, score)
        }.filter { $0.1 > 0.05 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// For the model's system prompt.
    static func promptSection(_ recalled: [MemoryEntry]) -> String {
        guard !recalled.isEmpty else { return "" }
        return "What you remember (from the user and earlier runs):\n"
            + recalled.map { "- " + ($0.topic.isEmpty ? "" : "[\($0.topic)] ") + $0.text }.joined(separator: "\n")
    }

    // MARK: - format

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func render(_ entries: [MemoryEntry]) -> String {
        entries.map { e in
            "<!-- \(stamp.string(from: e.date)) [\(e.id)] -->\n#\(e.kind.rawValue) "
                + (e.topic.isEmpty ? "" : "[[\(e.topic)]] ") + e.text
        }.joined(separator: "\n\n") + (entries.isEmpty ? "" : "\n")
    }

    static func parse(_ text: String) -> [MemoryEntry] {
        var out: [MemoryEntry] = []
        var header: (Date, String)?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<!--"), let m = line.range(of: #"<!-- (.+) \[([0-9a-z]+)\] -->"#, options: .regularExpression) {
                let inner = String(line[m]).dropFirst(5).dropLast(4)
                let parts = inner.split(separator: "[")
                let date = stamp.date(from: parts[0].trimmingCharacters(in: .whitespaces)) ?? Date()
                header = (date, parts.last.map { String($0.dropLast()) } ?? "")
                continue
            }
            guard line.hasPrefix("#"), let (date, id) = header else { continue }
            var rest = Substring(line.dropFirst())
            let kindWord = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(kindWord.count).drop { $0.isWhitespace }
            var topic = ""
            if rest.hasPrefix("[["), let end = rest.range(of: "]]") {
                topic = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])
                rest = rest[end.upperBound...].drop { $0.isWhitespace }
            }
            out.append(MemoryEntry(id: id, date: date, kind: MemoryEntry.Kind(rawValue: String(kindWord)) ?? .fact,
                                   topic: topic, text: String(rest)))
            header = nil
        }
        return out
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.render(entries).write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - helpers

    /// Never kept: passwords, one-time codes, card / ID / long account numbers.
    static func sensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = ["password", "passcode", "密码", "验证码", "verification code", "cvv", "身份证", "银行卡", "card number", "pin "]
        if words.contains(where: lower.contains) { return true }
        return text.range(of: #"\d[\d -]{5,}\d"#, options: .regularExpression) != nil
    }

    static func topicSlug(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(.init(charactersIn: "-")))
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard chars.count > 1 else { return Set(chars.map { String($0) }) }
        return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
    }

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}
