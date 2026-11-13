import Foundation

/// Henry 2026-11-13: words added while a run goes ("only the ones from March", "skip the pinned one"). They wait in
/// a queue and join the next round: each becomes a `steer` row in the trace (the review shows it), the prompt
/// lists every one so far under the goal, and that round goes to the planner, so the plan follows them. A model
/// call already on its way is not cancelled.
extension AgentLoop {
    static let steerAction = "steer"

    /// Queues `text` for the next round. False when it is empty or no run is going.
    @discardableResult func steer(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, !text.isEmpty else { return false }
        steering.append(String(text.prefix(500)))
        DebugLog.write("steer: queued for the next round (\(steering.count) waiting)")
        return true
    }

    /// The queued words into the trace, and the next round to the planner; called before a round is asked.
    func takeSteering() {
        guard !steering.isEmpty else { return }
        for text in steering { record(nil, ["action": .str(Self.steerAction), "text": .str(text)]) }
        steering = []
        checkpoints.asked = "the user added to the task"
    }

    /// Everything the user added this run, for the round's prompt (empty when nothing was).
    var steeredSection: String {
        let added = steps.filter { $0["action"]?.str == Self.steerAction }.compactMap { $0["text"]?.str }
        guard !added.isEmpty else { return "" }
        return "\n\nThe user added while you worked (follow these; the last one wins where they differ):\n"
            + added.map { "- " + $0 }.joined(separator: "\n")
    }
}
