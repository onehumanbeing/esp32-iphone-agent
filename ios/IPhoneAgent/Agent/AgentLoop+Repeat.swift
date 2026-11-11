import Foundation

/// The same gesture right after it left the screen unchanged is not sent at once: the model is asked once more in
/// the same round, with a line in its history saying so. Told "screen did NOT change", a model still often picks the
/// very same action; another target, a scroll, Back or asking for help is what moves a run on.
/// At most once per round: the same answer again is sent, so NoProgress, TouchCheck and the stall count still see
/// the repeats. Pure: the loop feeds the new reply's actions and the steps so far.
enum RepeatGuard {
    /// The step's action name (not a move: nothing was sent).
    static let action = "blocked"
    /// Gestures held back: all but Home, whose second press is not the same (Pointer.goHome flicks up then).
    static let held = Actions.gestures.subtracting(["home"])

    /// The new round's first gesture, when it is the same as the previous round's last one (NoProgress.same) and
    /// that left the screen unchanged (the verdict the stall count uses). Anything recorded in between (reconnected,
    /// help, a user's takeover) means the screen may be new: nil.
    static func repeated(_ acts: [JObject], after steps: [JObject]) -> JObject? {
        guard let first = acts.first(where: { Actions.gestures.contains($0["action"]?.str ?? "") }),
              held.contains(first["action"]?.str ?? ""),
              let last = steps.last(where: { $0["plan"] == nil }),
              Actions.gestures.contains(last["action"]?.str ?? ""), last["changed"] == .bool(false),
              NoProgress.same([first], [last]) else { return nil }
        return first
    }

    /// The line the model reads in its history: what was not done and what else there is.
    static func reason(_ action: String) -> String {
        "Not done: the same \(action) just left the screen unchanged. "
            + "Choose a different way (another target, scroll, back, open the app, or ask for help)."
    }
}

extension AgentLoop {
    /// The round's actions (nextActions), asked for once more when they start with a repeat of a gesture that just
    /// changed nothing. Not after a round a pause dropped (the flag is taken here): the person may have changed the
    /// screen meanwhile.
    func decide() async throws -> [Planned] {
        let afterPause = roundDroppedByPause
        roundDroppedByPause = false
        let acts = try await nextActions()
        guard !afterPause, let held = RepeatGuard.repeated(acts.map(\.act), after: steps) else { return acts }
        let name = held["action"]?.str ?? ""
        DebugLog.write("repeat guard: the same \(name) again right after it changed nothing; asking once more")
        var row: JObject = ["action": .str(RepeatGuard.action), "reason": .str(RepeatGuard.reason(name))]
        if acts[0].act["jev"] != nil { row["jev"] = .bool(true) }
        record(acts[0].shot, row)
        // the user's model answers this one (on both lines): Jev reads the same plan and would offer the same step
        checkpoints.asked = "repeat"  // the planner answers the second ask (free line)
        let hold = JevGate.hold
        JevGate.hold = true
        defer { JevGate.hold = hold }
        var again = try await nextActions()
        let both = (acts[0].act["think_s"]?.double ?? 0) + (again[0].act["think_s"]?.double ?? 0)
        again[0].act["think_s"] = .num((both * 100).rounded() / 100)  // the round's thinking: both calls
        return again
    }
}
