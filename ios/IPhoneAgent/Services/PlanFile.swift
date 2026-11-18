import CryptoKit
import Foundation

/// One intent's saved plan as a Markdown file in the Files tab's Plans folder (PlanCache): a small header the app
/// reads, then the plan as the user sees and edits it.
///
///     ---
///     format: 1
///     intent: 5F0C…            the intent it belongs to
///     name: Cleaning           the intent's name when saved (the page's title)
///     instruction: 3a9e…       PlanCache.key of the intent's words: other words, and the plan is stale
///     from-run: 20261118-1012  the run it came from
///     saved: 2026-11-18T10:12:00Z
///     plan-sha: 9b1d…          the body as the app wrote it: a different body is the user's edit
///     ---
///     1. Orders tab …
///
/// Forward compatible: unknown header lines are kept as they are and ignored; a file without the header is not a plan.
struct PlanFile: Equatable {
    static let format = 1

    var format = Self.format
    var intent: UUID
    var name: String
    var key: String
    var run: String
    var saved: Date
    var sha: String
    var plan: String
    /// Header lines this app does not know (a newer app's), written back unchanged.
    var extra: [String] = []

    init(intent: SavedTask, plan: String, run: String, saved: Date) {
        self.intent = intent.id
        name = intent.name
        key = PlanCache.key(intent)
        self.run = run
        self.saved = saved
        self.plan = plan
        sha = Self.hash(plan)
    }

    /// The user changed the body since the app wrote it.
    var edited: Bool { Self.hash(plan) != sha }
    /// Written by a newer app: read it, never write over it.
    var newer: Bool { format > Self.format }

    static func hash(_ text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(body.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ text: String) -> PlanFile? {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:], extra: [String] = []
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if known.contains(name) { fields[name] = value } else { extra.append(line) }
        }
        lines.removeSubrange(0...end)
        guard let id = fields["intent"].flatMap(UUID.init(uuidString:)), let key = fields["instruction"] else { return nil }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var file = PlanFile(intent: SavedTask(id: id, name: fields["name"] ?? "", prompt: ""), plan: body,
                            run: fields["from-run"] ?? "", saved: fields["saved"].flatMap(date) ?? .distantPast)
        file.key = key
        file.format = fields["format"].flatMap(Int.init) ?? 1
        file.sha = fields["plan-sha"] ?? file.sha  // no hash: taken as the app's own text
        file.extra = extra
        return file
    }

    var text: String {
        var head = ["format: \(format)", "intent: \(intent.uuidString)", "name: \(oneLine(name))", "instruction: \(key)",
                    "from-run: \(run)", "saved: \(ISO8601DateFormatter().string(from: saved))", "plan-sha: \(sha)"]
        head += extra
        return "---\n" + head.joined(separator: "\n") + "\n---\n\n" + plan.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static let known: Set<String> = ["format", "intent", "name", "instruction", "from-run", "saved", "plan-sha"]
    private static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
    private func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
}
