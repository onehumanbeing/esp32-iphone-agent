import Foundation

/// Henry 2026-11-13: an intent's instruction edited by hand ("type ok" became "write a comment on what you see")
/// left its title and steps as they were, so the next run typed "ok" or looked for a Send button with nothing typed.
/// After an edit the model checks the saved steps (in words, never a spot or a screen) against the new words and
/// proposes a title, one change per step and the checklist; nothing changes until the user applies it.
enum Replan {
    static let prompt = """
    You keep a saved iPhone task consistent after its owner changed the instruction. You get the old and the new \
    instruction, the saved steps in words and the checklist. Reply in this format only:
    NAME: <short name for the new task>
    STEP <n>: keep | drop | type "text" | ai "what to achieve"
    (one STEP line per saved step, in order)
    HINTS:
    - <hint>
    Keep a step the new task still needs as it is. Use type "…" for a step that types words the new instruction \
    changed, ai "…" for a step that now depends on what the screen shows (for example writing a comment about it), \
    drop for a step the new task no longer needs. HINTS: the checklist hints that still hold, at most 6. Keep the \
    user's language.
    """

    enum Edit: Equatable { case keep, drop, type(String), ai(String) }

    struct Proposal: Equatable {
        var name: String
        var edits: [Edit]
        var hints: [String]
        var changes: Int { edits.filter { $0 != .keep }.count }
    }

    static func input(old: String, new: String, steps: [RecordedStep], checklist: [String]) -> String {
        var lines = ["Old instruction: \(old)", "New instruction: \(new)", "Saved steps:"]
        for (i, step) in steps.enumerated() {
            lines.append("\(i + 1). " + (step.object.map { Replay.words($0) } ?? "(unreadable)"))
        }
        lines.append("Checklist:" + (checklist.isEmpty ? " (none)" : "\n" + checklist.map { "- " + $0 }.joined(separator: "\n")))
        return lines.joined(separator: "\n")
    }

    /// nil when the reply names no step at all; a step it leaves out is kept.
    static func parse(_ reply: String, count: Int) -> Proposal? {
        var name = "", edits = Array(repeating: Edit.keep, count: count), hints: [String] = [], seen = false, inHints = false
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("NAME:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces); continue }
            if upper.hasPrefix("HINTS:") { inHints = true; continue }
            if inHints, line.hasPrefix("-") || line.hasPrefix("•") {
                let hint = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !hint.isEmpty { hints.append(hint) }
                continue
            }
            guard upper.hasPrefix("STEP"), let colon = line.firstIndex(of: ":"),
                  let n = Int(line[line.index(line.startIndex, offsetBy: 4)..<colon].trimmingCharacters(in: .whitespaces)),
                  edits.indices.contains(n - 1) else { continue }
            seen = true
            let command = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let head = command.prefix { !$0.isWhitespace }.lowercased()
            let rest = command.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch head {
            case "drop": edits[n - 1] = .drop
            case "type" where !rest.isEmpty: edits[n - 1] = .type(rest)
            case "ai" where !rest.isEmpty: edits[n - 1] = .ai(rest)
            default: edits[n - 1] = .keep
            }
        }
        return seen ? Proposal(name: name, edits: edits, hints: Array(hints.prefix(6))) : nil
    }

    /// The steps with the proposal applied; a step keeps its reference screen.
    static func apply(_ edits: [Edit], to steps: [RecordedStep]) -> [RecordedStep] {
        var out: [RecordedStep] = []
        for (i, step) in steps.enumerated() {
            switch i < edits.count ? edits[i] : .keep {
            case .keep: out.append(step)
            case .drop: break
            case .type(let text):
                out.append(RecordedStep(action: ["action": .str("type"), "text": .str(text)], sure: true, frame: step.frame))
            case .ai(let goal):
                out.append(RecordedStep(action: ["action": .str("ai"), "goal": .str(goal)], sure: true, frame: step.frame))
            }
        }
        return out
    }

    /// One line for the sheet: what a step becomes.
    static func describe(_ edit: Edit, step: RecordedStep) -> String {
        let was = step.object.map { Replay.words($0) } ?? ""
        switch edit {
        case .keep: return was
        case .drop: return String(localized: "Remove: \(was)")
        case .type(let text): return String(localized: "Type \"\(text)\" (was: \(was))")
        case .ai(let goal): return String(localized: "AI: \(goal) (was: \(was))")
        }
    }
}

extension AppModel {
    /// The model's proposal for an intent whose instruction changed from `old` (Replan).
    func replan(_ item: SavedTask, old: String) async throws -> Replan.Proposal {
        let steps = item.steps ?? []
        if MockMode.on {
            try await Task.sleep(nanoseconds: 800_000_000)
            return Replan.Proposal(name: item.name, edits: steps.map { _ in .keep }, hints: item.checklist)
        }
        let reply = try await settings.client("planner").chat(
            system: Replan.prompt, text: Replan.input(old: old, new: item.prompt, steps: steps, checklist: item.checklist),
            image: nil, maxTokens: 700, temperature: 0)
        guard let proposal = Replan.parse(reply.text, count: steps.count) else {
            throw LLMError(message: String(localized: "The model did not check the steps."))
        }
        return proposal
    }
}
