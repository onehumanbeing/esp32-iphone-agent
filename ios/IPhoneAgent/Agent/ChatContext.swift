import Foundation

/// Turns of a chat as prompt text, and the summary a run leaves when it stops. No model call: built from the steps.
enum ChatContext {
    static let maxChars = 2500

    /// The last few turns, newest last, cut to fit: what was asked, how it ended, the answer and collected items.
    static func render(_ turns: [ChatTurn], limit: Int = 4) -> String {
        var parts: [String] = []
        for t in turns.suffix(limit) {
            var s = "User: \(t.ask)\nResult (\(t.outcome)): \(t.answer)"
            if !t.items.isEmpty {
                s += "\nCollected \(t.items.count) items: " + t.items.prefix(30).joined(separator: "; ")
                if t.items.count > 30 { s += "; …" }
            }
            if !t.summary.isEmpty { s += "\n" + t.summary }
            parts.append(s)
        }
        var out = parts.joined(separator: "\n\n")
        if out.count > maxChars { out = "…" + out.suffix(maxChars) }
        return out
    }

    /// "继续" / "continue": go on with the last turn's task where it stopped.
    static func isContinue(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return ["继续", "接着做", "继续做", "continue", "go on", "keep going", "resume"].contains(t)
    }

    /// What a run did and what is left, from its steps and notebook (for the chat and a later "continue").
    static func stopSummary(steps: [JObject], plan: String, notebook: Notebook) -> String {
        let moves = steps.filter { !StepText.notMoves.contains($0["action"]?.str ?? "") }
        let last = steps.last
        var out = "Stopped after \(moves.count) step\(moves.count == 1 ? "" : "s")"
        if let action = last?["action"]?.str, action != "done" {
            let why = last?["reason"]?.str ?? ""
            out += why.isEmpty ? " (\(action))" : " (\(action): \(why.prefix(160)))"
        }
        out += "."
        if let lastMove = moves.last { out += " Last action: " + PyJSON.dumps(Actions.key(lastMove).without(["reason"])).prefix(160) + "." }
        if !notebook.progress.isEmpty { out += " Progress: \(notebook.progress)." }
        if !notebook.items.isEmpty { out += " \(notebook.items.count) items collected." }
        if !plan.isEmpty { out += "\nPlan was:\n" + plan.prefix(500) }
        return out
    }
}
