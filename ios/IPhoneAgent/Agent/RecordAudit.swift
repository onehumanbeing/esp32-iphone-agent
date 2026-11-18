import Foundation

/// RECORD runs: before the first done, the planner model checks the records against every text line the run's
/// screens showed, and the run goes on to fix what it finds. Henry 2026-11-19: of 24 orders in a Meituan list, 4
/// were never opened and 3 were kept under a product's name instead of the shop's; "可以有个检查机制", up to about a
/// dollar a run. The reader (Qwen) still writes the records; the planner only checks them.
enum RecordAudit {
    static let maxRounds = 2
    static let maxLines = 4000  // unique lines kept from the screens (a long list: ~2000)
    static let maxReply = 1200

    static let system = """
        You check what a phone agent collected before it finishes. You get the goal, the facts to keep for every \
        item (RECORD), the records kept, and every text line the agent's screens showed during the run, in the order \
        first seen: lists, item pages, ads and recommendations mixed.
        Find, for items the goal asks for:
        MISSING: an item shown in a list of the user's own items (orders, bookings, messages) within the goal's range \
        that has no record. Name it as the list shows it, with its amount or date when shown next to it.
        NAME: a record whose name is not the item's own name on the screens (a product, a brand or a generic word \
        instead of the shop or title). Give the right name.
        FIELD: a record missing a fact the goal needs, which the screens show or should show on its page.
        EXTRA: a record outside the goal's range, or two records for one item.
        Never count recommendations, ads, shops or items the user did not order. When an item's place in a list \
        sorted by time shows it is in or out of the range, say so.
        Reply OK when nothing is wrong. Else one line per problem, at most 12, each starting with MISSING:, NAME:, \
        FIELD: or EXTRA:.
        """

    static func prompt(goal: String, fields: [String], records: [String], seen: [String]) -> String {
        "Goal: \(goal)\nRECORD: \(fields.joined(separator: ", "))\n\nRecords kept (\(records.count)):\n"
            + records.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            + "\n\nText the screens showed (\(seen.count) lines, first seen first):\n" + seen.joined(separator: "\n")
    }

    /// The problems in the reply, nil when it says OK (or names none).
    static func problems(_ reply: String) -> String? {
        let lines = reply.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")) }
            .filter { l in ["MISSING:", "NAME:", "FIELD:", "EXTRA:"].contains { l.uppercased().hasPrefix($0) } }
        guard !lines.isEmpty else { return nil }
        return String(lines.prefix(12).joined(separator: "\n").prefix(maxReply))
    }

    static func reason(_ problems: String) -> String {
        "Not done yet: a check of the records against the screens of this run found:\n" + problems
            + "\nFix these first: open each missing item (the reader records it), unfold what is folded; a wrong name "
            + "or a record that does not count: note the item again as its page shows it. Then finish."
    }

    /// Lines worth keeping from a screen: not the clock or bare numbers alone.
    static func keep(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.count <= 80 && !t.allSatisfy { $0.isNumber || $0 == ":" }
    }
}

/// Unique screen lines of the run, in the order first seen.
struct SeenLines {
    private(set) var lines: [String] = []
    private var known = Set<String>()

    mutating func add(_ texts: [String]) {
        for t in texts where lines.count < RecordAudit.maxLines && RecordAudit.keep(t) {
            let line = t.trimmingCharacters(in: .whitespaces)
            if known.insert(line).inserted { lines.append(line) }
        }
    }
}

extension AgentLoop {
    /// Before a done of a RECORD run: the planner's check, as a reason to go on; nil to let the done through.
    func recordAudit(_ acts: [JObject]) async -> String? {
        guard acts.contains(where: { $0["action"]?.str == "done" }), reader != nil, !recordFields.isEmpty,
              recordAudits < RecordAudit.maxRounds, let planner, !notebook.notes.isEmpty else { return nil }
        recordAudits += 1
        let started = now()
        // the free line takes model calls with a screen only: the screen now goes along
        let image = screen?.frame.map(ModelImage.forModel)
        let text = RecordAudit.prompt(goal: task, fields: recordFields, records: notebook.notes, seen: seenLines.lines)
        guard let reply = try? await planner.chat(system: RecordAudit.system, text: text, image: image,
                                                  maxTokens: 4000, temperature: 0) else {
            DebugLog.write("record audit: the planner did not answer; the done goes through")
            return nil
        }
        let found = RecordAudit.problems(reply.text)
        DebugLog.write(String(format: "record audit %d: %@ (%.1f s, %d records, %d screen lines)", recordAudits,
                              found.map { "\($0.components(separatedBy: "\n").count) problems" } ?? "OK",
                              now() - started, notebook.notes.count, seenLines.lines.count))
        trace?.write(kind: "audit", ["text": .str(found ?? "OK"), "seconds": .num(((now() - started) * 100).rounded() / 100)])
        return found.map(RecordAudit.reason)
    }
}
